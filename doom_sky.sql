/* =====================================================================
   doom_sky.sql -- stage 8. Sky, and a p_frame that stops moving.

   Run after doom_doors.sql.

   Sky is the cheapest pass in the renderer because it has no geometry: no
   depth, no perspective, no clipping. The column depends only on where you
   are looking and the row is the screen row. It fills whatever no surface
   claimed, which is exactly the pixels where an F_SKY1 ceiling was skipped.

   Doom maps a full turn to 1024 sky columns (a 32-bit BAM angle shifted
   right by 22) and then wraps into a 256-wide texture, so the sky repeats
   FOUR TIMES around you rather than once. Vertically dc_texturemid is 100 at
   unit scale, which reduces to texture row = screen row.

   Verified in the reference before transliterating: turning exactly 90
   degrees produces a pixel-identical sky, which is what four wraps per turn
   predicts. (It did not, at first: the column angle goes negative on the
   right of the screen and truncation-toward-zero broke the wrap. FLOOR is
   required, and the SQL below uses the same positive-remainder guard.)

   p_frame is redefined here for the LAST time. Every optional stage is
   called behind an OBJECT_ID check, so later files (weapons, AI) can add
   themselves without taking ownership of it again.
   ===================================================================== */

IF OBJECT_ID('dbo.p_frame')    IS NOT NULL DROP PROCEDURE dbo.p_frame;
IF OBJECT_ID('dbo.render_sky') IS NOT NULL DROP PROCEDURE dbo.render_sky;
GO
IF OBJECT_ID('dbo.sky_setting') IS NOT NULL DROP TABLE dbo.sky_setting;
GO

/* Which sky this map uses. Doom picks by episode: SKY1 for E1, SKY2 for E2,
   SKY3 for E3, SKY4 for E4. One row, so changing map is an UPDATE. */
CREATE TABLE dbo.sky_setting (
    id           tinyint NOT NULL PRIMARY KEY DEFAULT 1,
    texture_name varchar(8) NOT NULL
);
INSERT INTO dbo.sky_setting (id, texture_name) VALUES (1, 'SKY1');
GO

CREATE PROCEDURE dbo.render_sky @ang float
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @W int = 320, @H int = 200, @CX float = 160.0, @PROJ float = 160.0;

    DECLARE @tex int, @tw int, @th int;
    SELECT @tex = t.id, @tw = t.width, @th = t.height
    FROM dbo.texture t
    JOIN dbo.sky_setting s ON s.texture_name = t.name
    WHERE s.id = 1;

    IF @tex IS NULL RETURN;          -- no sky texture loaded; leave holes black

    /* one row per screen column: which sky column it shows. 320 rows, not
       64,000 -- the angle work does not belong in the per-pixel join. */
    ;WITH col AS (
        SELECT x = CONVERT(smallint, n.n),
               a = @ang + ATN2(@CX - n.n, @PROJ)
        FROM dbo.numbers n
        WHERE n.n >= 0 AND n.n < @W
    ),
    mapped AS (
        SELECT c.x,
               /* FLOOR, not CONVERT(int): the angle is negative on the right
                  half of the screen and truncation toward zero breaks the
                  wrap. Then force a positive remainder. */
               u = ((CONVERT(int, FLOOR(c.a / (2 * PI()) * 1024)) % @tw) + @tw) % @tw
        FROM col c
    )
    INSERT INTO dbo.framebuffer (x, y, pal_idx, light)
    SELECT sp.x, sp.y,
           CONVERT(tinyint, SUBSTRING(tc.pixels,
               CASE WHEN sp.y < @th THEN sp.y ELSE @th - 1 END + 1, 1)),
           0                          -- sky is always full bright
    FROM dbo.screen_pixel sp
    JOIN mapped m ON m.x = sp.x
    JOIN dbo.texture_column tc ON tc.texture_id = @tex AND tc.u = m.u
    WHERE NOT EXISTS (SELECT 1 FROM dbo.framebuffer fb
                      WHERE fb.x = sp.x AND fb.y = sp.y);
END
GO

/* ---------------------------------------------------------------------
   The final p_frame. Order matters: walls, then sky into the holes they
   left, then sprites over both, then the weapon over everything. Each
   optional stage is guarded, so adding one later means creating a procedure
   with the right name -- not editing this file again.
   --------------------------------------------------------------------- */
CREATE PROCEDURE dbo.p_frame @tics int = 4, @use bit = 0, @fire bit = 0,
                            @weapon tinyint = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @weapon > 0 AND OBJECT_ID('dbo.p_select_weapon') IS NOT NULL
        EXEC dbo.p_select_weapon @weapon;
    IF @use = 1 AND OBJECT_ID('dbo.p_use') IS NOT NULL
        EXEC dbo.p_use;
    IF @fire = 1 AND OBJECT_ID('dbo.p_fire') IS NOT NULL
        EXEC dbo.p_fire;

    DECLARE @i int = 0;
    WHILE @i < @tics
    BEGIN
        EXEC dbo.p_tick;
        IF OBJECT_ID('dbo.p_door_tick')   IS NOT NULL EXEC dbo.p_door_tick;
        IF OBJECT_ID('dbo.p_weapon_tick') IS NOT NULL EXEC dbo.p_weapon_tick;
        IF OBJECT_ID('dbo.p_pickup')      IS NOT NULL EXEC dbo.p_pickup;
        SET @i += 1;
    END

    DECLARE @px float, @py float, @ang float;
    SELECT @px = x, @py = y, @ang = angle FROM dbo.player WHERE id = 1;

    EXEC dbo.render_frame @px, @py, @ang;

    IF OBJECT_ID('dbo.render_sky')     IS NOT NULL EXEC dbo.render_sky @ang;
    IF OBJECT_ID('dbo.render_sprites') IS NOT NULL
        EXEC dbo.render_sprites @px, @py, @ang;
    IF OBJECT_ID('dbo.render_psprite') IS NOT NULL EXEC dbo.render_psprite;
    IF OBJECT_ID('dbo.render_hud')     IS NOT NULL EXEC dbo.render_hud;

    SELECT bmp = dbo.frame_bmp();
END
GO
