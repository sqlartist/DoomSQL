/* =====================================================================
   doom_present.sql -- stage 3b. Getting the frame out of the database.

   Additive: replaces dbo.frame_bmp and adds a timing harness. Does not
   touch dbo.render_frame, so nothing already working changes.

   The old frame_bmp built its pixel grid as numbers CROSS JOIN numbers
   (4096 x 4096 = 16.7M rows) and filtered down to 64,000. Whether the
   predicates get pushed below the join is up to the optimiser, and with an
   ordered STRING_AGG on top it frequently isn't. A materialised 64,000-row
   grid removes the question entirely.
   ===================================================================== */

IF OBJECT_ID('dbo.render_and_time') IS NOT NULL DROP PROCEDURE dbo.render_and_time;
IF OBJECT_ID('dbo.frame_bmp')       IS NOT NULL DROP FUNCTION dbo.frame_bmp;
GO
IF OBJECT_ID('dbo.le4')             IS NOT NULL DROP FUNCTION dbo.le4;
GO
IF OBJECT_ID('dbo.screen_pixel')    IS NOT NULL DROP TABLE dbo.screen_pixel;
GO

/* The screen, once. Clustered in scan order so the aggregate below reads it
   in the order it needs and the sort disappears from the plan. */
CREATE TABLE dbo.screen_pixel (
    y smallint NOT NULL,
    x smallint NOT NULL,
    CONSTRAINT pk_screen_pixel PRIMARY KEY (y, x)
);
GO

INSERT INTO dbo.screen_pixel (y, x)
SELECT ny.n, nx.n
FROM (SELECT n FROM dbo.numbers WHERE n < 200) ny
CROSS JOIN (SELECT n FROM dbo.numbers WHERE n < 320) nx;
GO

/* Little-endian 4-byte int. CONVERT(binary(4), n) is big-endian, and BMP
   headers are not. */
CREATE FUNCTION dbo.le4 (@v int) RETURNS binary(4) AS
BEGIN
    RETURN CONVERT(binary(1), @v % 256)
         + CONVERT(binary(1), (@v / 256) % 256)
         + CONVERT(binary(1), (@v / 65536) % 256)
         + CONVERT(binary(1), (@v / 16777216) % 256);
END
GO

/* 24-bit BMP. Rows bottom-up, BGR, and 320 x 3 = 960 is a multiple of 4 so
   there is no row padding to worry about.

   Aggregated per scanline first, then across scanlines: 200 concatenations
   of 1,920 characters instead of one of 384,000, which keeps each STRING_AGG
   well inside its comfort zone. */
CREATE FUNCTION dbo.frame_bmp () RETURNS varbinary(max)
AS
BEGIN
    DECLARE @w int = 320, @h int = 200;

    DECLARE @hex varchar(max) = (
        SELECT STRING_AGG(CONVERT(varchar(max), r.row_hex), '')
               WITHIN GROUP (ORDER BY r.y DESC)
        FROM (
            SELECT sp.y,
                   row_hex = STRING_AGG(CONVERT(varchar(max),
                         CONVERT(char(2), CONVERT(binary(1), COALESCE(p.b, 0)), 2)
                       + CONVERT(char(2), CONVERT(binary(1), COALESCE(p.g, 0)), 2)
                       + CONVERT(char(2), CONVERT(binary(1), COALESCE(p.r, 0)), 2)), '')
                       WITHIN GROUP (ORDER BY sp.x ASC)
            FROM dbo.screen_pixel sp
            LEFT JOIN dbo.framebuffer f
                   ON f.y = sp.y AND f.x = sp.x
            LEFT JOIN dbo.v_palette_rgb p
                   ON p.light_level = f.light AND p.in_idx = f.pal_idx
            GROUP BY sp.y
        ) r);

    RETURN 0x424D
         + dbo.le4(54 + @w * @h * 3) + 0x00000000 + dbo.le4(54)
         + dbo.le4(40) + dbo.le4(@w) + dbo.le4(@h)
         + 0x0100 + 0x1800 + dbo.le4(0) + dbo.le4(@w * @h * 3)
         + dbo.le4(2835) + dbo.le4(2835) + dbo.le4(0) + dbo.le4(0)
         + CONVERT(varbinary(max), @hex, 2);
END
GO

/* ---------------------------------------------------------------------
   Phase timings, so the guesswork stops. Run it twice and read the second
   result: the first call pays ~750ms to compile render_frame, and that cost
   is one-off as long as the plan stays cached.

       EXEC dbo.render_and_time;
       EXEC dbo.render_and_time;
   --------------------------------------------------------------------- */
CREATE PROCEDURE dbo.render_and_time
    @px float = NULL, @py float = NULL, @ang float = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @px IS NULL
        SELECT TOP 1 @px = x, @py = y, @ang = RADIANS(CONVERT(float, angle))
        FROM dbo.thing WHERE type = 1;

    DECLARE @t0 datetime2 = SYSUTCDATETIME();
    EXEC dbo.render_frame @px, @py, @ang;
    DECLARE @t1 datetime2 = SYSUTCDATETIME();
    IF OBJECT_ID('dbo.render_sprites') IS NOT NULL
        EXEC dbo.render_sprites @px, @py, @ang;
    DECLARE @ts datetime2 = SYSUTCDATETIME();
    DECLARE @bmp varbinary(max) = dbo.frame_bmp();
    DECLARE @t2 datetime2 = SYSUTCDATETIME();

    SELECT render_ms  = DATEDIFF(millisecond, @t0, @t1),
           sprite_ms  = DATEDIFF(millisecond, @t1, @ts),
           present_ms = DATEDIFF(millisecond, @ts, @t2),
           total_ms   = DATEDIFF(millisecond, @t0, @t2),
           fps        = CONVERT(decimal(5, 2),
                        1000.0 / NULLIF(DATEDIFF(millisecond, @t0, @t2), 0)),
           pixels_lit = (SELECT COUNT(*) FROM dbo.framebuffer),
           bmp_bytes  = DATALENGTH(@bmp);
END
GO
