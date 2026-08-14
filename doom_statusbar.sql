/* =====================================================================
   doom_statusbar.sql -- stage 10. The bar at the bottom.

   Run after doom_weapons.sql, then load hud.sql for the graphics.

   Nothing here touches p_frame: doom_sky.sql calls render_hud behind an
   OBJECT_ID guard, like every other optional stage.

   Two notes on the graphics. These are ordinary Doom picture-format
   patches -- the same format as wall patches and sprites -- but they sit
   loose in the WAD rather than between markers, so gen_hud.py names them
   explicitly. And V_DrawPatch SUBTRACTS the offsets: a patch asked for at
   (143,168) with leftoffset -5 actually lands at 148.

   The one new idea is right-aligned numbers. Doom's STlib_drawNum walks
   digits from the right, moving left by the digit width each time; the
   number's RIGHT edge sits at the widget's x. Set-based, that is: take the
   decimal string, join a numbers table over its characters, and place
   character i at right_x - (len - i) * digit_width. The whole bar then
   becomes one list of (patch, x, y) rows and a single blit.
   ===================================================================== */

IF OBJECT_ID('dbo.render_hud') IS NOT NULL DROP PROCEDURE dbo.render_hud;
GO
IF OBJECT_ID('dbo.hud_column') IS NOT NULL DROP TABLE dbo.hud_column;
IF OBJECT_ID('dbo.hud_patch')  IS NOT NULL DROP TABLE dbo.hud_patch;
GO

CREATE TABLE dbo.hud_patch (
    id       int NOT NULL PRIMARY KEY,
    name     varchar(12) NOT NULL UNIQUE,
    width    smallint NOT NULL,
    height   smallint NOT NULL,
    left_off smallint NOT NULL,
    top_off  smallint NOT NULL
);

CREATE TABLE dbo.hud_column (
    patch_id int NOT NULL REFERENCES dbo.hud_patch(id),
    u        smallint NOT NULL,
    pixels   varbinary(512) NOT NULL,
    alpha    varbinary(512) NULL,
    CONSTRAINT pk_hud_column PRIMARY KEY (patch_id, u)
);
GO

CREATE PROCEDURE dbo.render_hud AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @W int = 320, @H int = 200, @ST_Y int = 168;

    DECLARE @health int, @armour int, @bullets int, @shells int,
            @cells int, @rockets int, @weapons int, @cur tinyint;
    SELECT @health = health, @armour = armour, @bullets = bullets,
           @shells = shells, @cells = cells, @rockets = rockets,
           @weapons = weapons, @cur = cur_weapon
    FROM dbo.inventory WHERE id = 1;

    IF @health IS NULL RETURN;      -- setup_player has not run

    /* ammo shown in the big box is whatever the held weapon uses */
    DECLARE @cur_ammo int = (
        SELECT CASE w.ammo WHEN 'bullets' THEN @bullets
                           WHEN 'shells'  THEN @shells
                           WHEN 'cells'   THEN @cells
                           WHEN 'rockets' THEN @rockets END
        FROM dbo.weapon w WHERE w.id = @cur);

    ;WITH
    /* ---- the fixed pieces */
    fixed_part(name, x, y) AS (
        SELECT CONVERT(varchar(12), 'STBAR'),   0,   @ST_Y
        UNION ALL SELECT CONVERT(varchar(12), 'STARMS'),  104, @ST_Y
        UNION ALL SELECT CONVERT(varchar(12), 'STFST01'), 143, @ST_Y
        UNION ALL SELECT CONVERT(varchar(12), 'STTPRCNT'), 90, 171   -- after health
        UNION ALL SELECT CONVERT(varchar(12), 'STTPRCNT'), 221, 171  -- after armour
    ),
    /* ---- every number on the bar: value, right edge, row, digit style */
    num_field(val, right_x, y, prefix) AS (
        SELECT @health,  90, 171, CONVERT(varchar(8), 'STTNUM')
        UNION ALL SELECT @armour, 221, 171, CONVERT(varchar(8), 'STTNUM')
        UNION ALL SELECT @cur_ammo, 44, 171, CONVERT(varchar(8), 'STTNUM')
        UNION ALL SELECT @bullets, 288, 173, 'STYSNUM'
        UNION ALL SELECT @shells,  288, 179, 'STYSNUM'
        UNION ALL SELECT @cells,   288, 185, 'STYSNUM'
        UNION ALL SELECT @rockets, 288, 191, 'STYSNUM'
        UNION ALL SELECT 200, 314, 173, 'STYSNUM'   -- the maxima are fixed
        UNION ALL SELECT 50,  314, 179, 'STYSNUM'
        UNION ALL SELECT 300, 314, 185, 'STYSNUM'
        UNION ALL SELECT 50,  314, 191, 'STYSNUM'
    ),
    /* STlib_drawNum, set-based: character i of the decimal string lands at
       right_x - (len - i) * digit_width, so the right edge is at right_x */
    digit AS (
        SELECT name = CONVERT(varchar(12), f.prefix + SUBSTRING(t.txt, n.n + 1, 1)),
               x = f.right_x - (LEN(t.txt) - n.n) * dw.width,
               y = f.y
        FROM num_field f
        CROSS APPLY (SELECT txt = CONVERT(varchar(4), f.val)) t
        JOIN dbo.hud_patch dw ON dw.name = f.prefix + '0'
        JOIN dbo.numbers n ON n.n < LEN(t.txt)
        WHERE f.val IS NOT NULL
    ),
    /* ---- the arms box: yellow if owned, grey if not */
    arms AS (
        /* POWER() returns float and & is integer-only, hence the CONVERT */
        SELECT name = CONVERT(varchar(12),
                      CASE WHEN @weapons & CONVERT(int, POWER(2, w.id - 1)) <> 0
                           THEN 'STYSNUM' ELSE 'STGNUM' END)
                      + CONVERT(varchar(2), w.id),
               -- widened so the UNION in `elem` cannot truncate
               x = 111 + ((w.id - 2) % 3) * 12,
               y = 172 + ((w.id - 2) / 3) * 10
        FROM dbo.weapon w
        WHERE w.id BETWEEN 2 AND 7
    ),
    /* ---- one list of patches to blit, in draw order */
    elem AS (
        SELECT name, x, y, ord = 0 FROM fixed_part
        UNION ALL SELECT name, x, y, 1 FROM digit
        UNION ALL SELECT name, x, y, 2 FROM arms
    ),
    /* V_DrawPatch subtracts the offsets */
    placed AS (
        SELECT p.id AS patch_id, p.width, p.height,
               sx = e.x - p.left_off, sy = e.y - p.top_off, e.ord
        FROM elem e
        JOIN dbo.hud_patch p ON p.name = e.name
    ),
    px AS (
        SELECT pl.patch_id, pl.ord,
               x = CONVERT(smallint, nx.n), y = CONVERT(smallint, ny.n),
               u = nx.n - pl.sx, v = ny.n - pl.sy
        FROM placed pl
        JOIN dbo.numbers nx ON nx.n >= pl.sx AND nx.n < pl.sx + pl.width
                           AND nx.n >= 0 AND nx.n < @W
        JOIN dbo.numbers ny ON ny.n >= pl.sy AND ny.n < pl.sy + pl.height
                           AND ny.n >= 0 AND ny.n < @H
    ),
    sampled AS (
        SELECT p.x, p.y, p.ord,
               pal_idx = CONVERT(tinyint, SUBSTRING(hc.pixels, p.v + 1, 1))
        FROM px p
        JOIN dbo.hud_column hc
          ON hc.patch_id = p.patch_id AND hc.u = p.u
        WHERE hc.alpha IS NULL
           OR CONVERT(tinyint, SUBSTRING(hc.alpha, p.v + 1, 1)) = 1
    ),
    /* later elements draw over earlier ones: the bar first, then numbers */
    winner AS (
        SELECT x, y, pal_idx,
               rn = ROW_NUMBER() OVER (PARTITION BY x, y ORDER BY ord DESC)
        FROM sampled
    )
    SELECT x, y, pal_idx INTO #hud FROM winner WHERE rn = 1;

    DELETE fb FROM dbo.framebuffer fb JOIN #hud h ON h.x = fb.x AND h.y = fb.y;
    INSERT INTO dbo.framebuffer (x, y, pal_idx, light)
    SELECT x, y, pal_idx, 0 FROM #hud;     -- the bar is full bright
    DROP TABLE #hud;
END
GO

PRINT 'Status bar loaded. Now run hud.sql for the graphics.';
