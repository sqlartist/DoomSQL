/* =====================================================================
   doom_display_check.sql -- is the black screen SQL's fault or the client's?

   Run this on its own. It renders one frame from the player's current
   position and reports, in order: whether any pixels were written, what the
   palette join makes of them, and whether the BMP bytes are actually
   non-zero. The first line that looks wrong is the culprit.
   ===================================================================== */

SET NOCOUNT ON;

/* ---- 1. render from wherever the player currently is */
DECLARE @px float, @py float, @ang float;
SELECT @px = x, @py = y, @ang = angle FROM dbo.player WHERE id = 1;
IF @px IS NULL
BEGIN
    PRINT 'no player row -- running setup_game first';
    EXEC dbo.setup_game;
    SELECT @px = x, @py = y, @ang = angle FROM dbo.player WHERE id = 1;
END

SELECT step = '1. player', x = @px, y = @py, angle_rad = @ang,
       viewz = (SELECT floor_h + 41 FROM dbo.sector WHERE id = dbo.sector_at(@px, @py));

EXEC dbo.render_frame @px, @py, @ang;

/* ---- 2. did the rasteriser write anything? */
SELECT step = '2. framebuffer',
       pixels_lit = COUNT(*),
       distinct_pal = COUNT(DISTINCT pal_idx),
       min_light = MIN(light), max_light = MAX(light),
       verdict = CASE WHEN COUNT(*) = 0
                      THEN 'EMPTY -- rasteriser produced nothing, see doom_diagnose.sql'
                      ELSE 'ok' END
FROM dbo.framebuffer;

/* ---- 3. does the palette join survive? A framebuffer row whose (light,
   pal_idx) finds no match in v_palette_rgb becomes black via COALESCE. */
SELECT step = '3. palette join',
       framebuffer_rows = COUNT(*),
       matched = SUM(CASE WHEN p.in_idx IS NOT NULL THEN 1 ELSE 0 END),
       unmatched = SUM(CASE WHEN p.in_idx IS NULL THEN 1 ELSE 0 END),
       /* tinyint + tinyint stays tinyint in SQL Server and overflows past
          255, so widen before summing */
       non_black = SUM(CASE WHEN CONVERT(int, p.r) + CONVERT(int, p.g)
                               + CONVERT(int, p.b) > 0 THEN 1 ELSE 0 END)
FROM dbo.framebuffer f
LEFT JOIN dbo.v_palette_rgb p
       ON p.light_level = f.light AND p.in_idx = f.pal_idx;

/* if anything is unmatched, show what it was looking for */
SELECT TOP 5 step = '3b. unmatched sample', f.light, f.pal_idx, hits = COUNT(*)
FROM dbo.framebuffer f
LEFT JOIN dbo.v_palette_rgb p
       ON p.light_level = f.light AND p.in_idx = f.pal_idx
WHERE p.in_idx IS NULL
GROUP BY f.light, f.pal_idx;

/* ---- 4. are the BMP bytes actually non-zero? A 192054-byte result that is
   all zeros is a black image; this counts the non-zero ones in the pixel
   area, skipping the 54-byte header. */
DECLARE @bmp varbinary(max) = dbo.frame_bmp();
DECLARE @n int = 0, @i int = 55, @len int = DATALENGTH(@bmp);
DECLARE @sample int = 0;
WHILE @i <= @len AND @i < 30000          -- sample the first ~10k pixels
BEGIN
    IF SUBSTRING(@bmp, @i, 1) <> 0x00 SET @n += 1;
    SET @sample += 1;
    SET @i += 1;
END

SELECT step = '4. bmp bytes',
       total_bytes = @len,
       expected = 54 + 320 * 200 * 3,
       header_ok = CASE WHEN SUBSTRING(@bmp, 1, 2) = 0x424D THEN 'BM ok' ELSE 'BAD MAGIC' END,
       sampled = @sample, non_zero = @n,
       verdict = CASE WHEN @len <> 54 + 320 * 200 * 3 THEN 'WRONG SIZE'
                      WHEN @n = 0 THEN 'ALL ZERO -- the image really is black'
                      ELSE 'bytes look like an image; suspect the client' END;

/* ---- 5. a look at the frame as text, so you can see shape without a client.
   Each row is one screen row sampled every 8 columns; '#' is a lit pixel. */
SELECT step = '5. ascii preview', y = f.y,
       row_ = STRING_AGG(CASE WHEN f.pal_idx IS NULL THEN ' ' ELSE '#' END, '')
              WITHIN GROUP (ORDER BY f.x)
FROM (SELECT sp.y, sp.x, fb.pal_idx
      FROM dbo.screen_pixel sp
      LEFT JOIN dbo.framebuffer fb ON fb.x = sp.x AND fb.y = sp.y
      WHERE sp.x % 8 = 0 AND sp.y % 8 = 0) f
GROUP BY f.y
ORDER BY f.y;
