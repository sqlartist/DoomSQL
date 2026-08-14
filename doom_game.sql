/* =====================================================================
   doom_game.sql -- stage 4. Movement, collision, and the tick.

   This is what turns a renderer into a port. Doom's simulation runs at a
   fixed 35 tics per second; nothing requires the renderer to keep up, so
   p_tick and render_frame are decoupled and you can run the simulation at
   full rate with a slower view.

   P_TryMove stays set-based: the candidate blocking lines are one query, the
   blocking rules are a WHERE, and the outcome is one UPDATE.

   DIVERGENCE FROM VANILLA, stated up front: Doom tests a 16-unit AABB
   against each line via P_BoxOnLineSide. This uses point-to-segment distance
   against a 16-unit radius instead -- better behaved at corners, marginally
   different, and not demo-compatible. Everything else here follows vanilla
   constants.
   ===================================================================== */

IF OBJECT_ID('dbo.game_loop')     IS NOT NULL DROP PROCEDURE dbo.game_loop;
IF OBJECT_ID('dbo.walk_test')     IS NOT NULL DROP PROCEDURE dbo.walk_test;
IF OBJECT_ID('dbo.p_tick')        IS NOT NULL DROP PROCEDURE dbo.p_tick;
IF OBJECT_ID('dbo.p_input')       IS NOT NULL DROP PROCEDURE dbo.p_input;
IF OBJECT_ID('dbo.setup_game')    IS NOT NULL DROP PROCEDURE dbo.setup_game;
IF OBJECT_ID('dbo.build_collision') IS NOT NULL DROP PROCEDURE dbo.build_collision;
IF OBJECT_ID('dbo.move_blocked')  IS NOT NULL DROP FUNCTION dbo.move_blocked;
GO
IF OBJECT_ID('dbo.line_collide')  IS NOT NULL DROP TABLE dbo.line_collide;
IF OBJECT_ID('dbo.input_state')   IS NOT NULL DROP TABLE dbo.input_state;
IF OBJECT_ID('dbo.player')        IS NOT NULL DROP TABLE dbo.player;
GO

CREATE TABLE dbo.player (
    id      tinyint NOT NULL PRIMARY KEY DEFAULT 1,
    x       float NOT NULL,
    y       float NOT NULL,
    z       float NOT NULL,          -- feet, i.e. floor height
    angle   float NOT NULL,          -- radians
    momx    float NOT NULL DEFAULT 0,
    momy    float NOT NULL DEFAULT 0,
    sector_id int NULL,
    tic     int NOT NULL DEFAULT 0
);

/* Held keys, not events: the client UPDATEs a row on key down and key up,
   which is race-free without needing a queue. */
CREATE TABLE dbo.input_state (
    k     varchar(12) NOT NULL PRIMARY KEY,
    down  bit NOT NULL DEFAULT 0
);
INSERT INTO dbo.input_state (k, down) VALUES
    ('forward',0), ('back',0), ('turnleft',0), ('turnright',0),
    ('strafeleft',0), ('straferight',0), ('run',0), ('use',0);

/* The collision broad phase. BLOCKMAP is a spatial index, so this is one
   too -- just an ordinary B-tree on an expanded bounding box rather than a
   grid of buckets. At ~1,200 lines that beats a real spatial index; swap in
   a geometry column and STIntersects if you'd rather, the narrow phase below
   doesn't care which produced the candidates. */
CREATE TABLE dbo.line_collide (
    linedef_id   int NOT NULL PRIMARY KEY,
    x1 float NOT NULL, y1 float NOT NULL,
    x2 float NOT NULL, y2 float NOT NULL,
    minx float NOT NULL, miny float NOT NULL,
    maxx float NOT NULL, maxy float NOT NULL,
    one_sided    bit NOT NULL,
    flag_block   bit NOT NULL,
    open_top     float NULL,          -- NULL when one-sided
    open_bottom  float NULL
);
CREATE INDEX ix_line_collide_box ON dbo.line_collide (minx, maxx, miny, maxy);
GO

CREATE PROCEDURE dbo.build_collision AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dbo.line_collide;

    INSERT INTO dbo.line_collide (linedef_id, x1, y1, x2, y2,
        minx, miny, maxx, maxy, one_sided, flag_block, open_top, open_bottom)
    SELECT  l.id, a.x, a.y, b.x, b.y,
            CASE WHEN a.x < b.x THEN a.x ELSE b.x END,
            CASE WHEN a.y < b.y THEN a.y ELSE b.y END,
            CASE WHEN a.x > b.x THEN a.x ELSE b.x END,
            CASE WHEN a.y > b.y THEN a.y ELSE b.y END,
            CONVERT(bit, CASE WHEN l.left_sidedef IS NULL
                               OR l.right_sidedef IS NULL THEN 1 ELSE 0 END),
            CONVERT(bit, CASE WHEN l.flags & 1 = 1 THEN 1 ELSE 0 END),
            /* the opening a two-sided line leaves: what you can walk through */
            CASE WHEN fs.ceil_h < bs.ceil_h THEN fs.ceil_h ELSE bs.ceil_h END,
            CASE WHEN fs.floor_h > bs.floor_h THEN fs.floor_h ELSE bs.floor_h END
    FROM dbo.linedef l
    JOIN dbo.vertex a ON a.id = l.v1
    JOIN dbo.vertex b ON b.id = l.v2
    LEFT JOIN dbo.sidedef rsd ON rsd.id = l.right_sidedef
    LEFT JOIN dbo.sidedef lsd ON lsd.id = l.left_sidedef
    LEFT JOIN dbo.sector fs   ON fs.id = rsd.sector_id
    LEFT JOIN dbo.sector bs   ON bs.id = lsd.sector_id;

    SELECT lines_indexed = COUNT(*),
           solid = SUM(CONVERT(int, one_sided)),
           blocking_flag = SUM(CONVERT(int, flag_block))
    FROM dbo.line_collide;
END
GO

/* ---------------------------------------------------------------------
   P_TryMove's blocking test. Returns 1 if a 16-unit radius at (@nx,@ny)
   with feet at @z would hit something.

   Broad phase: the indexed bounding box, expanded by the radius.
   Narrow phase: point-to-segment distance.
   Rules: a one-sided line always blocks, so does the ML_BLOCKING flag; a
   two-sided line blocks if the opening is shorter than the player (56), if
   the ceiling is too low to stand under, or if the step up exceeds 24.
   --------------------------------------------------------------------- */
CREATE FUNCTION dbo.move_blocked (@nx float, @ny float, @z float)
RETURNS bit
AS
BEGIN
    DECLARE @r float = 16.0, @height float = 56.0, @maxstep float = 24.0;
    IF EXISTS (
        SELECT 1
        FROM dbo.line_collide c
        CROSS APPLY (SELECT dx = c.x2 - c.x1, dy = c.y2 - c.y1) d
        CROSS APPLY (SELECT len2 = d.dx * d.dx + d.dy * d.dy) e
        CROSS APPLY (SELECT t = CASE
                        WHEN e.len2 = 0 THEN 0.0
                        ELSE ((@nx - c.x1) * d.dx + (@ny - c.y1) * d.dy) / e.len2
                     END) f
        CROSS APPLY (SELECT tc = CASE WHEN f.t < 0 THEN 0.0
                                      WHEN f.t > 1 THEN 1.0
                                      ELSE f.t END) g
        CROSS APPLY (SELECT ddx = @nx - (c.x1 + g.tc * d.dx),
                            ddy = @ny - (c.y1 + g.tc * d.dy)) h
        WHERE @nx >= c.minx - @r AND @nx <= c.maxx + @r
          AND @ny >= c.miny - @r AND @ny <= c.maxy + @r
          AND h.ddx * h.ddx + h.ddy * h.ddy < @r * @r
          AND (   c.one_sided = 1
               OR c.flag_block = 1
               OR c.open_top IS NULL
               OR c.open_top - c.open_bottom < @height
               OR c.open_top - @z < @height
               OR c.open_bottom - @z > @maxstep)
    )
        RETURN 1;
    RETURN 0;
END
GO

CREATE PROCEDURE dbo.setup_game AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.player;
    UPDATE dbo.input_state SET down = 0;

    DECLARE @x float, @y float, @a float;
    SELECT TOP 1 @x = x, @y = y, @a = RADIANS(CONVERT(float, angle))
    FROM dbo.thing WHERE type = 1;

    DECLARE @sec int = dbo.sector_at(@x, @y);
    INSERT INTO dbo.player (id, x, y, z, angle, momx, momy, sector_id, tic)
    SELECT 1, @x, @y, s.floor_h, @a, 0, 0, @sec, 0
    FROM dbo.sector s WHERE s.id = @sec;

    SELECT * FROM dbo.player;
END
GO

CREATE PROCEDURE dbo.p_input @k varchar(12), @down bit AS
    UPDATE dbo.input_state SET down = @down WHERE k = @k;
GO

/* ---------------------------------------------------------------------
   One tic. Vanilla constants: friction 0.90625, walk thrust 0.78125 and
   run 1.5625 per tic, turn 640 and 1280 BAM (3.5 and 7 degrees), stopspeed
   0.0625. Thrust, then move, then friction -- P_XYMovement's order.
   --------------------------------------------------------------------- */
CREATE PROCEDURE dbo.p_tick AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @run bit = (SELECT down FROM dbo.input_state WHERE k = 'run');
    DECLARE @fwd float = CASE WHEN @run = 1 THEN 1.5625 ELSE 0.78125 END;
    DECLARE @side float = CASE WHEN @run = 1 THEN 1.25 ELSE 0.75 END;
    DECLARE @turn float = CASE WHEN @run = 1 THEN 0.12271846 ELSE 0.06135923 END;
    DECLARE @friction float = 0.90625, @stopspeed float = 0.0625;

    DECLARE @in_f int = (SELECT CONVERT(int, down) FROM dbo.input_state WHERE k = 'forward');
    DECLARE @in_b int = (SELECT CONVERT(int, down) FROM dbo.input_state WHERE k = 'back');
    DECLARE @in_tl int = (SELECT CONVERT(int, down) FROM dbo.input_state WHERE k = 'turnleft');
    DECLARE @in_tr int = (SELECT CONVERT(int, down) FROM dbo.input_state WHERE k = 'turnright');
    DECLARE @in_sl int = (SELECT CONVERT(int, down) FROM dbo.input_state WHERE k = 'strafeleft');
    DECLARE @in_sr int = (SELECT CONVERT(int, down) FROM dbo.input_state WHERE k = 'straferight');

    /* ---- turn, then thrust along the new facing */
    UPDATE dbo.player
       SET angle = angle + @turn * (@in_tl - @in_tr)
     WHERE id = 1;

    UPDATE dbo.player
       SET momx = momx + @fwd * (@in_f - @in_b) * COS(angle)
                       + @side * (@in_sr - @in_sl) * SIN(angle),
           momy = momy + @fwd * (@in_f - @in_b) * SIN(angle)
                       - @side * (@in_sr - @in_sl) * COS(angle)
     WHERE id = 1;

    /* ---- P_TryMove, with Doom's slide: if the full step is blocked, try
       each axis alone. Succeeding on one and not the other is what makes you
       slide along a wall instead of sticking to it. */
    DECLARE @x float, @y float, @z float, @mx float, @my float;
    SELECT @x = x, @y = y, @z = z, @mx = momx, @my = momy
    FROM dbo.player WHERE id = 1;

    IF dbo.move_blocked(@x + @mx, @y + @my, @z) = 0
        SELECT @x = @x + @mx, @y = @y + @my;
    ELSE
    BEGIN
        IF dbo.move_blocked(@x + @mx, @y, @z) = 0
            SELECT @x = @x + @mx, @my = 0;
        ELSE
            SET @mx = 0;
        IF dbo.move_blocked(@x, @y + @my, @z) = 0
            SET @y = @y + @my;
        ELSE
            SET @my = 0;
    END

    /* ---- land on whatever floor we ended up over */
    DECLARE @sec int = dbo.sector_at(@x, @y);
    DECLARE @floor float = (SELECT floor_h FROM dbo.sector WHERE id = @sec);

    /* ---- friction last, and kill tiny residuals so we come to a stop */
    SET @mx = @mx * @friction;
    SET @my = @my * @friction;
    IF ABS(@mx) < @stopspeed SET @mx = 0;
    IF ABS(@my) < @stopspeed SET @my = 0;

    UPDATE dbo.player
       SET x = @x, y = @y,
           z = COALESCE(@floor, z),
           sector_id = COALESCE(@sec, sector_id),
           momx = @mx, momy = @my,
           tic = tic + 1
     WHERE id = 1;
END
GO

/* Render whatever the player is currently looking at. */
CREATE PROCEDURE dbo.walk_test @tics int = 35 AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @i int = 0;
    DECLARE @log TABLE (tic int, x float, y float, z float,
                        speed float, sector_id int);
    WHILE @i < @tics
    BEGIN
        EXEC dbo.p_tick;
        INSERT INTO @log
        SELECT tic, x, y, z, SQRT(momx * momx + momy * momy), sector_id
        FROM dbo.player WHERE id = 1;
        SET @i += 1;
    END
    SELECT * FROM @log ORDER BY tic;

    DECLARE @px float, @py float, @ang float;
    SELECT @px = x, @py = y, @ang = angle FROM dbo.player WHERE id = 1;
    EXEC dbo.render_frame @px, @py, @ang;
    SELECT pixels_lit = COUNT(*) FROM dbo.framebuffer;
END
GO

/* ---------------------------------------------------------------------
   The loop. Simulation at 35Hz, render every @render_every tics so a slow
   rasteriser doesn't slow the game down. Run this in one session; poll
   dbo.frame_bmp() from another.

       EXEC dbo.setup_game;
       EXEC dbo.build_collision;
       EXEC dbo.p_input 'forward', 1;
       EXEC dbo.game_loop @seconds = 10;
   --------------------------------------------------------------------- */
CREATE PROCEDURE dbo.game_loop @seconds int = 10, @render_every int = 8 AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @until datetime2 = DATEADD(second, @seconds, SYSUTCDATETIME());
    DECLARE @n int = 0, @frames int = 0;
    DECLARE @px float, @py float, @ang float;

    WHILE SYSUTCDATETIME() < @until
    BEGIN
        EXEC dbo.p_tick;
        SET @n += 1;
        IF @n % @render_every = 0
        BEGIN
            SELECT @px = x, @py = y, @ang = angle FROM dbo.player WHERE id = 1;
            EXEC dbo.render_frame @px, @py, @ang;
            SET @frames += 1;
        END
        WAITFOR DELAY '00:00:00.028';        -- 35 tics per second
    END
    SELECT tics = @n, frames = @frames,
           tics_per_sec = CONVERT(decimal(6,2), @n * 1.0 / @seconds);
END
GO
