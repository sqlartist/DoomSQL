/* =====================================================================
   doom_sprites.sql -- stage 6. Things.

   Run after doom_render.sql. Load the sprite DATA from the generated
   <MAP>_sprites.sql afterwards.

   Two things worth understanding before reading the query.

   1. HERE THE Z-BUFFER IS CORRECT. The walls could not use a per-pixel
      argmin, because a plane's depth does not establish that the plane is
      visible (see doom_render.sql). A sprite is different: it is a flat
      billboard at ONE depth, so for overlapping sprites

          ROW_NUMBER() OVER (PARTITION BY x, y ORDER BY inv_z DESC)

      really is the right answer. Same operator, sound in one case and not
      the other, for a reason about the geometry rather than about SQL.

   2. CLIPPING AGAINST WALLS is the same prefix aggregation the wall pass
      uses, ranged on depth instead of ordered by it. For a sprite at depth
      d in column x: if any NEARER seg in that column was solid, the sprite
      is hidden; otherwise the running MAX/MIN of those segs' openings is the
      window it shows through.
   ===================================================================== */

IF OBJECT_ID('dbo.render_sprites') IS NOT NULL DROP PROCEDURE dbo.render_sprites;
GO
IF OBJECT_ID('dbo.sprite_column') IS NOT NULL DROP TABLE dbo.sprite_column;
IF OBJECT_ID('dbo.sprite_frame')  IS NOT NULL DROP TABLE dbo.sprite_frame;
IF OBJECT_ID('dbo.mobj_type')     IS NOT NULL DROP TABLE dbo.mobj_type;
IF OBJECT_ID('dbo.column_seg')    IS NOT NULL DROP TABLE dbo.column_seg;
GO

/* doomednum -> which sprite and frame it spawns in. This mapping lives in
   Doom's info.c, which is source code rather than data, so it is carried
   here as a table. Monsters spawn in frame A; corpses and some props spawn
   part-way through an animation. */
CREATE TABLE dbo.mobj_type (
    doomednum   int NOT NULL PRIMARY KEY,
    sprite      char(4) NOT NULL,
    frame       char(1) NOT NULL,
    full_bright bit NOT NULL
);

/* One row per (sprite, frame, rotation). Rotation 0 means the thing looks
   the same from every angle; otherwise 1-8 run anticlockwise from the front.
   `flip` marks the rotations that reuse another rotation's picture mirrored,
   which is how a lump called TROOA2A8 serves two directions. */
CREATE TABLE dbo.sprite_frame (
    id        int NOT NULL PRIMARY KEY,
    sprite    char(4) NOT NULL,
    frame     char(1) NOT NULL,
    rotation  tinyint NOT NULL,
    width     smallint NOT NULL,
    height    smallint NOT NULL,
    left_off  smallint NOT NULL,   -- picture hangs this far left of the thing
    top_off   smallint NOT NULL,   -- and this far above its feet
    flip      bit NOT NULL,
    lump      varchar(8) NOT NULL,
    CONSTRAINT uq_sprite_frame UNIQUE (sprite, frame, rotation)
);

/* Column-major, exactly like texture_column: sprites are the same picture
   format, and the renderer samples them the same way. */
CREATE TABLE dbo.sprite_column (
    frame_id  int NOT NULL REFERENCES dbo.sprite_frame(id),
    u         smallint NOT NULL,
    pixels    varbinary(1024) NOT NULL,
    alpha     varbinary(1024) NULL,     -- sprites are nearly all masked
    CONSTRAINT pk_sprite_column PRIMARY KEY (frame_id, u)
);

/* What the wall pass saw, per screen column. render_sprites fills this and
   then aggregates it; it is also the most useful thing to SELECT when a
   sprite appears through a wall. */
CREATE TABLE dbo.column_seg (
    x        smallint NOT NULL,
    inv_z    float NOT NULL,
    y_otop   float NOT NULL,      -- top of the opening this seg leaves
    y_obot   float NOT NULL,      -- bottom of it
    is_solid bit NOT NULL,        -- a one-sided wall: closes the column
    seg_id   int NOT NULL,
    CONSTRAINT pk_column_seg PRIMARY KEY (x, inv_z, seg_id)
);
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
DECLARE @view_deg float = DEGREES(@ang);

IF @viewz IS NULL
    SET @viewz = (SELECT floor_h + 41 FROM dbo.sector
                  WHERE id = dbo.sector_at(@px, @py));

/* ---- 1. what the walls left behind, per column. Same projection as
   render_frame's xform..visible chain; only the small stages, so it costs a
   fraction of a full render. */
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
    JOIN dbo.linedef l      ON l.id = s.linedef_id
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

/* ---- 2. the sprites themselves */
;WITH thing_vis AS (
    SELECT  t.id, t.x AS tx, t.y AS ty, t.angle AS tang,
            mt.sprite, mt.frame, mt.full_bright,
            v.z, v.lat,
            ang_to = DEGREES(ATN2(t.y - @py, t.x - @px))
    FROM dbo.thing t
    JOIN dbo.mobj_type mt ON mt.doomednum = t.type
    CROSS APPLY (SELECT
        z   = (t.x - @px) * @cos + (t.y - @py) * @sin,
        lat = (t.x - @px) * @sin - (t.y - @py) * @cos) v
    WHERE t.flags & 16 = 0            -- multiplayer-only things
      AND v.z >= @NEAR
),
/* rotation choice: 0 if the sprite has one, else one of 8 from where the
   viewer stands relative to the thing's facing (R_ProjectSprite) */
rot AS (
    /* SQL Server's % is integer-only, and these are floats, so normalise into
       [0,360) with FLOOR instead: r - 360*FLOOR(r/360). */
    SELECT tv.*,
           want_rot = CONVERT(tinyint, FLOOR(n.norm / 45.0) + 1)
    FROM thing_vis tv
    CROSS APPLY (SELECT rel = tv.ang_to - tv.tang + 202.5) r
    CROSS APPLY (SELECT norm = r.rel - 360.0 * FLOOR(r.rel / 360.0)) n
),
chosen AS (
    SELECT r.*,
           f.id AS frame_id, f.width, f.height, f.left_off, f.top_off, f.flip
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
            sec.floor_h,
            /* named sec_light, not light: the next CTE selects p.* and then
               defines its own `light`, and two columns of that name in one
               SELECT is an error (Msg 8156). */
            sec_light = sec.light,
            inv_z  = 1.0 / c.z,
            scale  = @PROJ / c.z,
            x0     = @CX + @PROJ * c.lat / c.z - c.left_off * (@PROJ / c.z),
            y0     = @CY - (sec.floor_h + c.top_off - @viewz) * (@PROJ / c.z),
            w_px   = c.width  * (@PROJ / c.z),
            h_px   = c.height * (@PROJ / c.z)
    FROM chosen c
    CROSS APPLY (SELECT sid = dbo.sector_at(c.tx, c.ty)) s
    JOIN dbo.sector sec ON sec.id = s.sid
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
/* ---- 3. sprite x screen column, with the wall clip applied */
sprite_col AS (
    SELECT  s.frame_id, s.inv_z, s.scale, s.x0, s.y0, s.h_px, s.w_px,
            s.height, s.width, s.flip, s.light,
            x = CONVERT(smallint, n.n),
            u = CASE WHEN s.flip = 1
                     THEN s.width - 1 - CONVERT(int, FLOOR((n.n - s.x0) / s.scale))
                     ELSE CONVERT(int, FLOOR((n.n - s.x0) / s.scale)) END,
            clip.ctop, clip.cbot
    FROM onscreen_sprite s
    JOIN dbo.numbers n
      ON n.n >= 0 AND n.n <= @W - 1
     AND n.n >= s.x0 AND n.n <= s.x0 + s.w_px
    /* the prefix aggregation, ranged on depth: everything NEARER than this
       sprite in this column decides whether and where it shows */
    CROSS APPLY (
        SELECT ctop = COALESCE(MAX(CEILING(cs.y_otop)), 0),
               cbot = COALESCE(MIN(FLOOR(cs.y_obot)), @H - 1),
               blocked = COALESCE(MAX(CONVERT(int, cs.is_solid)), 0)
        FROM dbo.column_seg cs
        WHERE cs.x = n.n AND cs.inv_z > s.inv_z
    ) clip
    WHERE clip.blocked = 0
),
bounded AS (
    SELECT sc.*,
           ytop = CASE WHEN sc.ctop < 0 THEN 0 ELSE CONVERT(int, sc.ctop) END,
           ybot = CASE WHEN sc.cbot > @H - 1 THEN @H - 1 ELSE CONVERT(int, sc.cbot) END
    FROM sprite_col sc
    WHERE sc.u >= 0 AND sc.u < sc.width
),
/* ---- 4. columns become rows */
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
/* ---- 5. texel fetch, transparent texels dropped */
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
/* ---- 6. overlapping sprites: nearest wins. Sound here, unlike for planes,
   because a sprite is a billboard at a single depth. */
winner AS (
    SELECT x, y, pal_idx, light,
           rn = ROW_NUMBER() OVER (PARTITION BY x, y ORDER BY inv_z DESC)
    FROM sampled
)
SELECT x, y, pal_idx, light
INTO #sprite_px
FROM winner WHERE rn = 1;

/* sprites paint over the walls */
DELETE fb FROM dbo.framebuffer fb
JOIN #sprite_px s ON s.x = fb.x AND s.y = fb.y;

INSERT INTO dbo.framebuffer (x, y, pal_idx, light)
SELECT x, y, pal_idx, light FROM #sprite_px;

DROP TABLE #sprite_px;
END
GO
