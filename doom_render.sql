/* =====================================================================
   doom_render.sql -- stage 3. The rasteriser.

   One frame = one INSERT ... SELECT. Doom's ceilingclip/floorclip arrays,
   maintained imperatively as R_RenderBSPNode walks front to back, are prefix
   scans: the clip bounds in force when a seg is drawn are the running MAX and
   MIN of every nearer seg's opening in that column. That is a window frame:

       MAX(open_top_y) OVER (PARTITION BY x ORDER BY depth
                             ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)

   Because those bounds are exact, every pixel is written exactly once and
   there is no z-buffer. A per-pixel argmin does NOT work here: a distant
   room's ceiling plane can be nearer than the one you are standing under, so
   it wins the argmin and paints over everything. Planes need visibility, not
   just depth. (I got that wrong first; see README.)

   This is a transliteration of render_ref.py, which was checked against
   FreeDoom E1M1 by rendering frames. Stage names below match its comments.

   RUN ORDER: doom_schema.sql -> <MAP>.sql (which embeds doom_textures.sql)
              -> doom_render.sql -> doom_present.sql -> doom_game.sql
   Re-running this file alone is safe; it owns only render_frame, sector_at
   and framebuffer. Afterwards you do NOT need to re-run anything else.
   ===================================================================== */

IF OBJECT_ID('dbo.render_frame') IS NOT NULL DROP PROCEDURE dbo.render_frame;
IF OBJECT_ID('dbo.sector_at')    IS NOT NULL DROP FUNCTION dbo.sector_at;
GO
IF OBJECT_ID('dbo.framebuffer')  IS NOT NULL DROP TABLE dbo.framebuffer;
GO

CREATE TABLE dbo.framebuffer (
    x        smallint NOT NULL,
    y        smallint NOT NULL,
    pal_idx  tinyint  NOT NULL,
    light    tinyint  NOT NULL,
    CONSTRAINT pk_framebuffer PRIMARY KEY (y, x)
);
GO

/* Descend the BSP to the leaf containing a point -- bsp_order() taking one
   child instead of both. Right child when the point is on the positive side;
   getting this backwards renders the whole map from above the ceilings. */
CREATE FUNCTION dbo.sector_at (@px float, @py float)
RETURNS int
AS
BEGIN
    DECLARE @idx int = (SELECT MAX(id) FROM dbo.node), @leaf bit = 0, @guard int = 0;
    DECLARE @x float, @y float, @dx float, @dy float,
            @rl bit, @rc int, @ll bit, @lc int;
    WHILE @leaf = 0 AND @guard < 64
    BEGIN
        SELECT @x = part_x, @y = part_y, @dx = part_dx, @dy = part_dy,
               @rl = r_is_leaf, @rc = r_child, @ll = l_is_leaf, @lc = l_child
        FROM dbo.node WHERE id = @idx;
        IF (@px - @x) * @dy - (@py - @y) * @dx > 0
            SELECT @leaf = @rl, @idx = @rc;
        ELSE
            SELECT @leaf = @ll, @idx = @lc;
        SET @guard += 1;
    END
    RETURN (SELECT ss.front_sector
            FROM dbo.subsector s
            JOIN dbo.seg_sector ss ON ss.seg_id = s.first_seg
            WHERE s.id = @idx);
END
GO

CREATE PROCEDURE dbo.render_frame
    @px float, @py float, @ang float, @viewz float = NULL
AS
BEGIN
SET NOCOUNT ON;

DECLARE @cos float = COS(@ang), @sin float = SIN(@ang);
DECLARE @W int = 320, @H int = 200;
DECLARE @CX float = 160.0, @CY float = 100.0;
DECLARE @PROJ float = 160.0, @NEAR float = 4.0, @FALLOFF float = 280.0;
DECLARE @UPPER_UNPEG int = 8, @LOWER_UNPEG int = 16;

IF @viewz IS NULL
    SET @viewz = (SELECT floor_h + 41 FROM dbo.sector
                  WHERE id = dbo.sector_at(@px, @py));

TRUNCATE TABLE dbo.framebuffer;

;WITH
/* ---- stage 1: view transform. Forward is (cos,sin); right is (sin,-cos). */
xform AS (
    SELECT  s.id, s.linedef_id, s.side, s.offset_u,
            sd.x_off, sd.y_off, sd.upper_tex, sd.lower_tex, sd.middle_tex,
            l.flags,
            f_ceil = fs.ceil_h, f_floor = fs.floor_h,
            f_ctex = fs.ceil_tex, f_ftex = fs.floor_tex,
            light0 = 31 - fs.light / 8,
            b_ceil = bs.ceil_h, b_floor = bs.floor_h,
            /* solid = ONE-SIDED only. A shut door is a two-sided line whose
               opening has closed to nothing; its texture is on the UPPER, and
               door sidedefs have no middle. Treating it as solid drew the
               absent middle and left a hole -- which the sky pass then filled,
               so closed doors appeared to have the sky painted on them. */
            is_solid = CONVERT(bit, CASE WHEN bs.id IS NULL THEN 1 ELSE 0 END),
            /* shut: two-sided but with no opening left. Still a portal for
               texture purposes; the degenerate opening closes the column by
               itself through the clip bounds. */
            shut = CONVERT(bit, CASE WHEN bs.id IS NOT NULL
                        AND CASE WHEN fs.ceil_h < bs.ceil_h
                                THEN fs.ceil_h ELSE bs.ceil_h END
                         <= CASE WHEN fs.floor_h > bs.floor_h
                                THEN fs.floor_h ELSE bs.floor_h END
                                    THEN 1 ELSE 0 END),
            v.z1, v.z2, v.l1, v.l2,
            u1 = 0.0,
            u2 = SQRT(SQUARE(CONVERT(float, b.x - a.x))
                    + SQUARE(CONVERT(float, b.y - a.y)))
    FROM dbo.seg s
    JOIN dbo.vertex a       ON a.id = s.v1
    JOIN dbo.vertex b       ON b.id = s.v2
    JOIN dbo.linedef l      ON l.id = s.linedef_id
    JOIN dbo.seg_sector ss  ON ss.seg_id = s.id
    JOIN dbo.sector fs      ON fs.id = ss.front_sector
    LEFT JOIN dbo.sector bs ON bs.id = ss.back_sector
    JOIN dbo.sidedef sd     ON sd.id = CASE WHEN s.side = 0
                                            THEN l.right_sidedef
                                            ELSE l.left_sidedef END
    CROSS APPLY (SELECT
        z1 = (a.x - @px) * @cos + (a.y - @py) * @sin,
        z2 = (b.x - @px) * @cos + (b.y - @py) * @sin,
        l1 = (a.x - @px) * @sin - (a.y - @py) * @cos,
        l2 = (b.x - @px) * @sin - (b.y - @py) * @cos) v
    /* backface cull: the front side is to the right of v1->v2 */
    WHERE (@px - a.x) * (b.y - a.y) - (@py - a.y) * (b.x - a.x) > 0
      AND NOT (v.z1 < @NEAR AND v.z2 < @NEAR)
),
/* ---- stage 2: near clip. Interpolate the crossing endpoint, don't drop it. */
clipped AS (
    SELECT  x.*,
            cz1 = CASE WHEN z1 < @NEAR THEN @NEAR ELSE z1 END,
            cz2 = CASE WHEN z2 < @NEAR THEN @NEAR ELSE z2 END,
            cl1 = CASE WHEN z1 < @NEAR
                       THEN l1 + (l2 - l1) * ((@NEAR - z1) / NULLIF(z2 - z1, 0))
                       ELSE l1 END,
            cl2 = CASE WHEN z2 < @NEAR
                       THEN l2 + (l1 - l2) * ((@NEAR - z2) / NULLIF(z1 - z2, 0))
                       ELSE l2 END,
            cu1 = CASE WHEN z1 < @NEAR
                       THEN u1 + (u2 - u1) * ((@NEAR - z1) / NULLIF(z2 - z1, 0))
                       ELSE u1 END,
            cu2 = CASE WHEN z2 < @NEAR
                       THEN u2 + (u1 - u2) * ((@NEAR - z2) / NULLIF(z1 - z2, 0))
                       ELSE u2 END
    FROM xform x
),
screen AS (
    SELECT  c.*,
            sx1 = @CX + @PROJ * cl1 / cz1,
            sx2 = @CX + @PROJ * cl2 / cz2
    FROM clipped c
),
onscreen AS (
    SELECT * FROM screen
    WHERE sx2 > sx1 AND sx2 >= 0 AND sx1 <= @W - 1
),
/* ---- stage 3: seg x screen column. 1/z is linear in screen x, so inv_z and
   u/z interpolate linearly and u recovers by dividing through. */
segcol AS (
    SELECT  o.*,
            x = CONVERT(smallint, n.n),
            inv_z = p.inv_z,
            u_world = o.offset_u + o.x_off
                    + (o.cu1 / o.cz1
                       + (o.cu2 / o.cz2 - o.cu1 / o.cz1) * q.t) / p.inv_z
    FROM onscreen o
    JOIN dbo.numbers n
      ON n.n >= 0 AND n.n <= @W - 1
     AND n.n >= CEILING(o.sx1) AND n.n <= FLOOR(o.sx2)
    CROSS APPLY (SELECT t = (n.n - o.sx1) / NULLIF(o.sx2 - o.sx1, 0)) q
    CROSS APPLY (SELECT inv_z = 1.0 / o.cz1
                              + (1.0 / o.cz2 - 1.0 / o.cz1) * q.t) p
    WHERE p.inv_z > 0
),
/* Projected screen lines for this seg's sector and, for portals, the opening. */
lines AS (
    SELECT  sc.*,
            y_ceil  = @CY - (sc.f_ceil  - @viewz) * @PROJ * sc.inv_z,
            y_floor = @CY - (sc.f_floor - @viewz) * @PROJ * sc.inv_z,
            y_otop  = @CY - (CASE WHEN sc.is_solid = 1 THEN sc.f_ceil
                                  WHEN sc.f_ceil < sc.b_ceil THEN sc.f_ceil
                                  ELSE sc.b_ceil END - @viewz) * @PROJ * sc.inv_z,
            y_obot  = @CY - (CASE WHEN sc.is_solid = 1 THEN sc.f_floor
                                  WHEN sc.f_floor > sc.b_floor THEN sc.f_floor
                                  ELSE sc.b_floor END - @viewz) * @PROJ * sc.inv_z,
            light   = CASE WHEN sc.light0 + (1.0 / sc.inv_z) / @FALLOFF < 0 THEN 0
                           WHEN sc.light0 + (1.0 / sc.inv_z) / @FALLOFF > 31 THEN 31
                           ELSE CONVERT(tinyint,
                                sc.light0 + (1.0 / sc.inv_z) / @FALLOFF) END
    FROM segcol sc
),
/* ---- stage 5: THE OCCLUSION. Doom's clip arrays as prefix scans. Each row
   sees the running bounds established by everything nearer in its column. */
occl AS (
    SELECT  l.*,
            closed_before = COALESCE(MAX(CONVERT(int, l.is_solid)) OVER (
                PARTITION BY l.x ORDER BY l.inv_z DESC, l.id
                ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0),
            cc_raw = COALESCE(MAX(CEILING(l.y_otop)) OVER (
                PARTITION BY l.x ORDER BY l.inv_z DESC, l.id
                ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0),
            fc_raw = COALESCE(MIN(FLOOR(l.y_obot)) OVER (
                PARTITION BY l.x ORDER BY l.inv_z DESC, l.id
                ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), @H - 1)
    FROM lines l
),
visible AS (
    /* Clamp each bound only on the side that keeps it inside the screen:
       ceil_clip from below, floor_clip from above. Clamping the OTHER side
       destroys the signal that the opening has closed to nothing -- a
       negative floor_clip pulled up to 0 leaves every remaining seg in the
       column with the range [0,0], and they all write row 0. That is a
       primary key violation in SQL and a silent overwrite in an array. */
    SELECT  o.*,
            ceil_clip  = CASE WHEN o.cc_raw < 0 THEN 0
                              ELSE CONVERT(int, o.cc_raw) END,
            floor_clip = CASE WHEN o.fc_raw > @H - 1 THEN @H - 1
                              ELSE CONVERT(int, o.fc_raw) END
    FROM occl o
    WHERE o.closed_before = 0        -- everything behind the first solid wall
),
/* ---- stage 4b: unpivot each seg-column into the surfaces it carries. */
surface AS (
    SELECT  v.x, v.inv_z, v.u_world, v.light, v.light0, v.y_off, v.ceil_clip,
            v.floor_clip, v.f_ceil, v.f_floor,
            s.slot, s.kind, s.tex_name, s.plane_h, s.origin_h, s.y_from, s.y_to
    FROM visible v
    CROSS APPLY (VALUES
        /* ceiling plane: from the running top clip down to where it meets
           this seg. Only when the ceiling is above the eye. */
        ('ceil', 'plane', v.f_ctex, CONVERT(float, v.f_ceil), CONVERT(float, 0),
         CONVERT(float, v.ceil_clip), CEILING(v.y_ceil) - 1),
        /* floor plane */
        ('floor', 'plane', v.f_ftex, CONVERT(float, v.f_floor), CONVERT(float, 0),
         FLOOR(v.y_floor) + 1, CONVERT(float, v.floor_clip)),
        /* solid wall: the whole opening */
        ('mid', 'wall', v.middle_tex, CONVERT(float, 0),
         CASE WHEN v.flags & @LOWER_UNPEG > 0
              THEN v.f_floor + COALESCE((SELECT height FROM dbo.texture
                                         WHERE name = v.middle_tex), 128)
              ELSE v.f_ceil END,
         v.y_ceil, v.y_floor),
        /* upper: front ceiling down to the opening top */
        ('upper', 'wall', v.upper_tex, CONVERT(float, 0),
         CASE WHEN v.flags & @UPPER_UNPEG > 0 THEN v.f_ceil
              ELSE v.b_ceil + COALESCE((SELECT height FROM dbo.texture
                                        WHERE name = v.upper_tex), 128) END,
         v.y_ceil,
         CASE WHEN v.shut = 1 THEN v.y_floor ELSE CEILING(v.y_otop) - 1 END),
        /* lower: opening bottom down to the front floor */
        ('lower', 'wall', v.lower_tex, CONVERT(float, 0),
         CASE WHEN v.flags & @LOWER_UNPEG > 0 THEN v.f_ceil
              ELSE CONVERT(float, v.b_floor) END,
         CASE WHEN v.shut = 1 THEN v.y_ceil ELSE FLOOR(v.y_obot) + 1 END,
         v.y_floor)
    ) s(slot, kind, tex_name, plane_h, origin_h, y_from, y_to)
    WHERE s.tex_name <> '-'
      AND s.tex_name <> 'F_SKY1'
      /* the column has closed: this is the reference's `break`, as a filter */
      AND v.ceil_clip <= v.floor_clip
      AND NOT (s.slot = 'ceil'  AND v.f_ceil  <= @viewz)
      AND NOT (s.slot = 'floor' AND v.f_floor >= @viewz)
      /* a solid seg carries only its middle; a portal only upper and lower,
         and only where the opening actually exposes them */
      AND NOT (s.slot = 'mid'   AND v.is_solid = 0)
      AND NOT (s.slot = 'upper' AND (v.is_solid = 1 OR v.b_ceil >= v.f_ceil))
      AND NOT (s.slot = 'lower' AND (v.is_solid = 1 OR v.b_floor <= v.f_floor))
      /* a shut portal is covered by its upper; the lower would overlap it and
         write the same pixel twice. It only draws if there is no upper. */
      AND NOT (s.slot = 'lower' AND v.shut = 1 AND v.upper_tex <> '-')
),
/* ---- stage 6: spans become rows. */
pixel AS (
    SELECT  s.*, y = CONVERT(smallint, n.n)
    FROM surface s
    JOIN dbo.numbers n
      ON n.n >= s.ceil_clip AND n.n <= s.floor_clip
     AND n.n >= s.y_from AND n.n <= s.y_to
),
/* ---- stage 7: texel fetch. Walls sample by (u along the wall, height);
   planes sample by the world point under the pixel. */
sampled AS (
    SELECT  p.x, p.y,
            t.id AS texture_id,
            u = CASE WHEN p.kind = 'wall'
                     THEN CONVERT(int, FLOOR(p.u_world)) % t.width
                     ELSE CONVERT(int, FLOOR(w.wx)) % t.width END,
            v = CASE WHEN p.kind = 'wall'
                     THEN CONVERT(int, FLOOR(p.origin_h - w.h_world + p.y_off))
                          % t.height
                     ELSE CONVERT(int, FLOOR(w.wy)) % t.height END,
            light = CASE WHEN p.kind = 'wall' THEN p.light
                         WHEN p.light0 + w.zf / @FALLOFF > 31 THEN 31
                         WHEN p.light0 + w.zf / @FALLOFF < 0 THEN 0
                         ELSE CONVERT(tinyint, p.light0 + w.zf / @FALLOFF) END
    FROM pixel p
    JOIN dbo.texture t ON t.name = p.tex_name
    CROSS APPLY (SELECT denom = p.y - @CY) d
    CROSS APPLY (SELECT zf = CASE WHEN p.kind = 'wall' OR d.denom = 0 THEN NULL
                                  ELSE (@viewz - p.plane_h) * @PROJ / d.denom END) z
    CROSS APPLY (SELECT
        h_world = @viewz + (@CY - p.y) * (1.0 / p.inv_z) / @PROJ,
        lat = (p.x - @CX) * z.zf / @PROJ) l0
    CROSS APPLY (SELECT
        h_world = l0.h_world,
        zf = z.zf,
        wx = @px + @cos * z.zf + @sin * l0.lat,
        wy = @py + @sin * z.zf - @cos * l0.lat) w
    WHERE p.kind = 'wall' OR (z.zf IS NOT NULL AND z.zf >= @NEAR)
)
INSERT INTO dbo.framebuffer (x, y, pal_idx, light)
SELECT  s.x, s.y,
        CONVERT(tinyint, SUBSTRING(tc.pixels,
            CASE WHEN s.v < 0 THEN s.v + t.height ELSE s.v END + 1, 1)),
        s.light
FROM sampled s
JOIN dbo.texture t ON t.id = s.texture_id
JOIN dbo.texture_column tc
  ON tc.texture_id = s.texture_id
 AND tc.u = CASE WHEN s.u < 0 THEN s.u + t.width ELSE s.u END
/* masked texels (grates, vines) are holes, not pixels */
WHERE tc.alpha IS NULL
   OR CONVERT(tinyint, SUBSTRING(tc.alpha,
        CASE WHEN s.v < 0 THEN s.v + t.height ELSE s.v END + 1, 1)) = 1;
END
GO

/* le4() and frame_bmp() deliberately do NOT live here. They are owned by
   doom_present.sql. Defining them in both meant that re-running this file to
   apply a rasteriser fix silently reinstated the slow frame_bmp and put ~1
   second per frame back on the clock. One object, one home. */

/* ---------------------------------------------------------------------
   Render one frame from the player 1 start:

     DECLARE @t TABLE (x smallint, y smallint, a float);
     DECLARE @px float, @py float, @ang float;
     SELECT TOP 1 @px = x, @py = y, @ang = RADIANS(CONVERT(float, angle))
     FROM dbo.thing WHERE type = 1;
     EXEC dbo.render_frame @px, @py, @ang;
     SELECT dbo.frame_bmp();          -- save the varbinary as .bmp
     SELECT COUNT(*) AS pixels_lit FROM dbo.framebuffer;
   --------------------------------------------------------------------- */
