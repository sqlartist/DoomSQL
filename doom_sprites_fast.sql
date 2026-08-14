/* =====================================================================
   doom_sprites_fast.sql -- stage 6b. Why sprites cost a second.

   Run after doom_sprites.sql and the sprite data load.

   THE PROBLEM. render_sprites called dbo.sector_at() inside the query, to
   find the floor each thing stands on. sector_at contains a WHILE loop, so
   SQL Server cannot inline it (Froid only handles single-expression scalar
   UDFs). A non-inlinable scalar UDF in a query is evaluated row by row AND
   FORCES THE WHOLE PLAN SERIAL -- which threw away the ~5x parallelism the
   wall pass gets, on top of the per-row cost.

   THE FIX. Things do not move, so their sector never changes. Compute it
   once at load time into a table and join to it. The UDF leaves the hot path
   entirely, and the query can go parallel again.

   Also adds column_solid: one row per screen column giving the depth of the
   nearest solid wall. A sprite behind it is invisible, and that is a cheap
   equijoin that discards most hidden sprite columns before the expensive
   range aggregate ever runs.
   ===================================================================== */

IF OBJECT_ID('dbo.build_thing_sector') IS NOT NULL DROP PROCEDURE dbo.build_thing_sector;
IF OBJECT_ID('dbo.render_sprites')     IS NOT NULL DROP PROCEDURE dbo.render_sprites;
GO
IF OBJECT_ID('dbo.column_solid')  IS NOT NULL DROP TABLE dbo.column_solid;
IF OBJECT_ID('dbo.thing_sector')  IS NOT NULL DROP TABLE dbo.thing_sector;
GO

/* Static per thing: which sector it stands in, and that sector's floor and
   light. Recompute only if the map changes. */
CREATE TABLE dbo.thing_sector (
    thing_id  int NOT NULL PRIMARY KEY,
    sector_id int NOT NULL,
    floor_h   smallint NOT NULL,
    light     smallint NOT NULL
);

/* One row per screen column: the depth of the nearest solid wall. */
CREATE TABLE dbo.column_solid (
    x            smallint NOT NULL PRIMARY KEY,
    solid_inv_z  float NOT NULL
);
GO

CREATE PROCEDURE dbo.build_thing_sector AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dbo.thing_sector;
    /* the scalar UDF runs here, once per thing, ONCE -- not per frame */
    INSERT INTO dbo.thing_sector (thing_id, sector_id, floor_h, light)
    SELECT t.id, s.id, s.floor_h, s.light
    FROM dbo.thing t
    CROSS APPLY (SELECT sid = dbo.sector_at(CONVERT(float, t.x),
                                            CONVERT(float, t.y))) a
    JOIN dbo.sector s ON s.id = a.sid
    WHERE EXISTS (SELECT 1 FROM dbo.mobj_type m WHERE m.doomednum = t.type);

    SELECT things_placed = COUNT(*) FROM dbo.thing_sector;
END
GO

CREATE PROCEDURE dbo.render_sprites
    @px float, @py float, @ang float, @viewz float = NULL
AS
BEGIN
SET NOCOUNT ON;

DECLARE @cos float = COS(@ang), @sin float = SIN(@ang);
DECLARE @W int = 320, @H int = 200;
DECLARE @CX float = 160.0, @CY float = 100.0;
DECLARE @PROJ float = 160.0, @NEAR float = 4.0, @FALLOFF float = 280.0;

/* the UDF is called once, in a scalar assignment, where it costs nothing */
IF @viewz IS NULL
    SET @viewz = (SELECT floor_h + 41 FROM dbo.sector
                  WHERE id = dbo.sector_at(@px, @py));

TRUNCATE TABLE dbo.column_seg;

;WITH xform AS (
    SELECT  s.id,
            f_ceil = fs.ceil_h, f_floor = fs.floor_h,
            b_ceil = bs.ceil_h, b_floor = bs.floor_h,
            is_solid = CONVERT(bit, CASE WHEN bs.id IS NULL
                        OR CASE WHEN fs.ceil_h < bs.ceil_h
                                THEN fs.ceil_h ELSE bs.ceil_h END
                         <= CASE WHEN fs.floor_h > bs.floor_h
                                THEN fs.floor_h ELSE bs.floor_h END
                                         THEN 1 ELSE 0 END),
            v.z1, v.z2, v.l1, v.l2
    FROM dbo.seg s
    JOIN dbo.vertex a       ON a.id = s.v1
    JOIN dbo.vertex b       ON b.id = s.v2
    JOIN dbo.seg_sector ss  ON ss.seg_id = s.id
    JOIN dbo.sector fs      ON fs.id = ss.front_sector
    LEFT JOIN dbo.sector bs ON bs.id = ss.back_sector
    CROSS APPLY (SELECT
        z1 = (a.x - @px) * @cos + (a.y - @py) * @sin,
        z2 = (b.x - @px) * @cos + (b.y - @py) * @sin,
        l1 = (a.x - @px) * @sin - (a.y - @py) * @cos,
        l2 = (b.x - @px) * @sin - (b.y - @py) * @cos) v
    WHERE (@px - a.x) * (b.y - a.y) - (@py - a.y) * (b.x - a.x) > 0
      AND NOT (v.z1 < @NEAR AND v.z2 < @NEAR)
),
clipped AS (
    SELECT x.*,
           cz1 = CASE WHEN z1 < @NEAR THEN @NEAR ELSE z1 END,
           cz2 = CASE WHEN z2 < @NEAR THEN @NEAR ELSE z2 END,
           cl1 = CASE WHEN z1 < @NEAR
                      THEN l1 + (l2 - l1) * ((@NEAR - z1) / NULLIF(z2 - z1, 0))
                      ELSE l1 END,
           cl2 = CASE WHEN z2 < @NEAR
                      THEN l2 + (l1 - l2) * ((@NEAR - z2) / NULLIF(z1 - z2, 0))
                      ELSE l2 END
    FROM xform x
),
screen AS (
    SELECT c.*, sx1 = @CX + @PROJ * cl1 / cz1, sx2 = @CX + @PROJ * cl2 / cz2
    FROM clipped c
),
onscreen AS (
    SELECT * FROM screen WHERE sx2 > sx1 AND sx2 >= 0 AND sx1 <= @W - 1
),
segcol AS (
    SELECT o.*, x = CONVERT(smallint, n.n), inv_z = p.inv_z
    FROM onscreen o
    JOIN dbo.numbers n
      ON n.n >= 0 AND n.n <= @W - 1
     AND n.n >= CEILING(o.sx1) AND n.n <= FLOOR(o.sx2)
    CROSS APPLY (SELECT t = (n.n - o.sx1) / NULLIF(o.sx2 - o.sx1, 0)) q
    CROSS APPLY (SELECT inv_z = 1.0 / o.cz1
                              + (1.0 / o.cz2 - 1.0 / o.cz1) * q.t) p
    WHERE p.inv_z > 0
)
INSERT INTO dbo.column_seg (x, inv_z, y_otop, y_obot, is_solid, seg_id)
SELECT sc.x, sc.inv_z,
       @CY - (CASE WHEN sc.is_solid = 1 THEN sc.f_ceil
                   WHEN sc.f_ceil < sc.b_ceil THEN sc.f_ceil
                   ELSE sc.b_ceil END - @viewz) * @PROJ * sc.inv_z,
       @CY - (CASE WHEN sc.is_solid = 1 THEN sc.f_floor
                   WHEN sc.f_floor > sc.b_floor THEN sc.f_floor
                   ELSE sc.b_floor END - @viewz) * @PROJ * sc.inv_z,
       sc.is_solid, sc.id
FROM segcol sc;

/* nearest solid wall per column: one cheap equijoin that kills most hidden
   sprite columns before the range aggregate has to look at them */
TRUNCATE TABLE dbo.column_solid;
INSERT INTO dbo.column_solid (x, solid_inv_z)
SELECT x, MAX(inv_z) FROM dbo.column_seg WHERE is_solid = 1 GROUP BY x;

/* ---- the sprites */
;WITH thing_vis AS (
    SELECT  t.id, t.x AS tx, t.y AS ty, t.angle AS tang,
            mt.sprite, mt.frame, mt.full_bright,
            ts.floor_h, sec_light = ts.light,
            v.z, v.lat,
            ang_to = DEGREES(ATN2(t.y - @py, t.x - @px))
    FROM dbo.thing t
    JOIN dbo.mobj_type mt   ON mt.doomednum = t.type
    JOIN dbo.thing_sector ts ON ts.thing_id = t.id   -- no scalar UDF here
    CROSS APPLY (SELECT
        z   = (t.x - @px) * @cos + (t.y - @py) * @sin,
        lat = (t.x - @px) * @sin - (t.y - @py) * @cos) v
    WHERE t.flags & 16 = 0
      AND v.z >= @NEAR
),
rot AS (
    /* % is integer-only in SQL Server and these are floats, so normalise
       into [0,360) with FLOOR: r - 360*FLOOR(r/360) */
    SELECT tv.*, want_rot = CONVERT(tinyint, FLOOR(n.norm / 45.0) + 1)
    FROM thing_vis tv
    CROSS APPLY (SELECT rel = tv.ang_to - tv.tang + 202.5) r
    CROSS APPLY (SELECT norm = r.rel - 360.0 * FLOOR(r.rel / 360.0)) n
),
chosen AS (
    SELECT r.*, f.id AS frame_id, f.width, f.height,
           f.left_off, f.top_off, f.flip
    FROM rot r
    OUTER APPLY (
        SELECT TOP 1 sf.*
        FROM dbo.sprite_frame sf
        WHERE sf.sprite = r.sprite AND sf.frame = r.frame
        ORDER BY CASE WHEN sf.rotation = 0 THEN 0
                      WHEN sf.rotation = r.want_rot THEN 1
                      ELSE 2 END, sf.rotation
    ) f
    WHERE f.id IS NOT NULL
),
placed AS (
    SELECT  c.*,
            inv_z = 1.0 / c.z,
            scale = @PROJ / c.z,
            x0    = @CX + @PROJ * c.lat / c.z - c.left_off * (@PROJ / c.z),
            y0    = @CY - (c.floor_h + c.top_off - @viewz) * (@PROJ / c.z),
            w_px  = c.width  * (@PROJ / c.z),
            h_px  = c.height * (@PROJ / c.z)
    FROM chosen c
),
onscreen_sprite AS (
    SELECT p.*,
           light = CASE WHEN p.full_bright = 1 THEN 0
                        WHEN 31 - p.sec_light / 8 + p.z / @FALLOFF > 31 THEN 31
                        WHEN 31 - p.sec_light / 8 + p.z / @FALLOFF < 0 THEN 0
                        ELSE CONVERT(tinyint,
                             31 - p.sec_light / 8 + p.z / @FALLOFF) END
    FROM placed p
    WHERE p.w_px >= 1 AND p.h_px >= 1
      AND p.x0 + p.w_px >= 0 AND p.x0 <= @W - 1
),
sprite_col AS (
    SELECT  s.frame_id, s.inv_z, s.scale, s.x0, s.y0, s.h_px, s.w_px,
            s.height, s.width, s.flip, s.light,
            x = CONVERT(smallint, n.n),
            u = CASE WHEN s.flip = 1
                     THEN s.width - 1 - CONVERT(int, FLOOR((n.n - s.x0) / s.scale))
                     ELSE CONVERT(int, FLOOR((n.n - s.x0) / s.scale)) END
    FROM onscreen_sprite s
    JOIN dbo.numbers n
      ON n.n >= 0 AND n.n <= @W - 1
     AND n.n >= s.x0 AND n.n <= s.x0 + s.w_px
    /* cheap first: behind the nearest solid wall in this column? gone. */
    LEFT JOIN dbo.column_solid cs ON cs.x = n.n
    WHERE cs.solid_inv_z IS NULL OR cs.solid_inv_z <= s.inv_z
),
/* only the survivors pay for the range aggregate over the portals in front */
clipped_col AS (
    SELECT sc.*,
           ctop = COALESCE(MAX(CEILING(k.y_otop)), 0),
           cbot = COALESCE(MIN(FLOOR(k.y_obot)), @H - 1)
    FROM sprite_col sc
    LEFT JOIN dbo.column_seg k
           ON k.x = sc.x AND k.inv_z > sc.inv_z AND k.is_solid = 0
    WHERE sc.u >= 0 AND sc.u < sc.width
    GROUP BY sc.frame_id, sc.inv_z, sc.scale, sc.x0, sc.y0, sc.h_px, sc.w_px,
             sc.height, sc.width, sc.flip, sc.light, sc.x, sc.u
),
bounded AS (
    SELECT c.*,
           ytop = CASE WHEN c.ctop < 0 THEN 0 ELSE CONVERT(int, c.ctop) END,
           ybot = CASE WHEN c.cbot > @H - 1 THEN @H - 1
                       ELSE CONVERT(int, c.cbot) END
    FROM clipped_col c
),
sprite_pixel AS (
    SELECT  b.frame_id, b.x, b.u, b.inv_z, b.light,
            y = CONVERT(smallint, n.n),
            v = CONVERT(int, FLOOR((n.n - b.y0) / b.scale))
    FROM bounded b
    JOIN dbo.numbers n
      ON n.n >= b.ytop AND n.n <= b.ybot
     AND n.n >= b.y0 AND n.n <= b.y0 + b.h_px
    WHERE b.ytop <= b.ybot
),
sampled AS (
    SELECT  p.x, p.y, p.inv_z, p.light,
            pal_idx = CONVERT(tinyint, SUBSTRING(sc.pixels, p.v + 1, 1))
    FROM sprite_pixel p
    JOIN dbo.sprite_frame sf ON sf.id = p.frame_id
    JOIN dbo.sprite_column sc
      ON sc.frame_id = p.frame_id AND sc.u = p.u
    WHERE p.v >= 0 AND p.v < sf.height
      AND (sc.alpha IS NULL
           OR CONVERT(tinyint, SUBSTRING(sc.alpha, p.v + 1, 1)) = 1)
),
/* nearest sprite wins. Sound here, unlike for planes, because a sprite is a
   billboard at a single depth. */
winner AS (
    SELECT x, y, pal_idx, light,
           rn = ROW_NUMBER() OVER (PARTITION BY x, y ORDER BY inv_z DESC)
    FROM sampled
)
SELECT x, y, pal_idx, light
INTO #sprite_px
FROM winner WHERE rn = 1;

DELETE fb FROM dbo.framebuffer fb
JOIN #sprite_px s ON s.x = fb.x AND s.y = fb.y;

INSERT INTO dbo.framebuffer (x, y, pal_idx, light)
SELECT x, y, pal_idx, light FROM #sprite_px;

DROP TABLE #sprite_px;
END
GO

PRINT 'Now run:  EXEC dbo.build_thing_sector;';
