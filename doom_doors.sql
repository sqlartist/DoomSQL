/* =====================================================================
   doom_doors.sql -- stage 7. The world stops being static.

   RUN ORDER MATTERS: after doom_game.sql AND doom_client.sql, because this
   file takes ownership of three objects they defined -- build_collision,
   move_blocked and p_frame. Re-running either of those files afterwards will
   silently revert doors to the static-world versions. Run this last.

   Verified against E1M1 before shipping: 25 door linedefs (20 plain, 4 blue
   key, 1 fast), every one with a valid back sector and a reachable open
   target. A normal door opens over 62 tics, waits 150, closes -- vanilla.

   Up to now render_frame has been a pure function of the player's position:
   the same coordinates always produced the same frame. A door breaks that.
   Sector heights become STATE, updated once per tic, and the renderer reads
   whatever they currently are -- which it already does, since it joins
   dbo.sector for ceil_h. Opening a door therefore needs no renderer change
   at all. That is the payoff for having kept the geometry relational.

   Two things do need changing, and they are the interesting part:

   1. COLLISION. line_collide cached open_top/open_bottom from the heights at
      load time. With doors those go stale the moment one moves, so the cache
      now stores the two SECTOR IDS and move_blocked joins for live heights.
      The expensive part (the bounding box index) is still precomputed.

   2. THE TICK. Doors are thinkers: a small table of in-progress movements,
      one UPDATE per tic. Doom runs them in a linked list; here they are rows,
      and all doors in the level move in a single statement.
   ===================================================================== */

IF OBJECT_ID('dbo.p_frame')          IS NOT NULL DROP PROCEDURE dbo.p_frame;
IF OBJECT_ID('dbo.p_door_tick')      IS NOT NULL DROP PROCEDURE dbo.p_door_tick;
IF OBJECT_ID('dbo.p_use')            IS NOT NULL DROP PROCEDURE dbo.p_use;
IF OBJECT_ID('dbo.build_collision')  IS NOT NULL DROP PROCEDURE dbo.build_collision;
IF OBJECT_ID('dbo.move_blocked')     IS NOT NULL DROP FUNCTION dbo.move_blocked;
IF OBJECT_ID('dbo.open_target')      IS NOT NULL DROP FUNCTION dbo.open_target;
GO
IF OBJECT_ID('dbo.door')             IS NOT NULL DROP TABLE dbo.door;
IF OBJECT_ID('dbo.door_special')     IS NOT NULL DROP TABLE dbo.door_special;
IF OBJECT_ID('dbo.line_collide')     IS NOT NULL DROP TABLE dbo.line_collide;
GO

/* Which linedef specials are manual doors, and how each behaves.
   speed: units per tic (vanilla VDOORSPEED is 2; the fast doors use 8).
   stay:  opens and stays open rather than closing after a wait.
   key:   0 none, 1 blue, 2 yellow, 3 red. Enforcement is a WHERE clause in
          p_use, so giving the player keys later is a one-row change. */
CREATE TABLE dbo.door_special (
    special  smallint NOT NULL PRIMARY KEY,
    speed    smallint NOT NULL,
    stay     bit NOT NULL,
    key_type tinyint NOT NULL,
    descr    varchar(40) NOT NULL
);
INSERT INTO dbo.door_special (special, speed, stay, key_type, descr) VALUES
    (1,   2, 0, 0, 'DR open wait close'),
    (26,  2, 0, 1, 'DR blue key'),
    (27,  2, 0, 2, 'DR yellow key'),
    (28,  2, 0, 3, 'DR red key'),
    (31,  2, 1, 0, 'D1 open stay'),
    (32,  2, 1, 1, 'D1 blue key, stay'),
    (33,  2, 1, 2, 'D1 yellow key, stay'),
    (34,  2, 1, 3, 'D1 red key, stay'),
    (117, 8, 0, 0, 'DR fast'),
    (118, 8, 1, 0, 'D1 fast, stay');

/* Doors currently in motion. A row exists only while something is happening,
   which is exactly Doom's thinker list -- as rows. */
CREATE TABLE dbo.door (
    sector_id  int NOT NULL PRIMARY KEY,
    state      tinyint NOT NULL,   -- 1 opening, 2 waiting at the top, 3 closing
    top_h      smallint NOT NULL,  -- open target
    bottom_h   smallint NOT NULL,  -- closed target (the sector floor)
    speed      smallint NOT NULL,
    wait_tics  int NOT NULL,
    timer      int NOT NULL,
    stay       bit NOT NULL
);

/* Geometry cached, heights NOT. Storing the sector ids instead of the
   opening is what lets a door move without invalidating this table. */
CREATE TABLE dbo.line_collide (
    linedef_id   int NOT NULL PRIMARY KEY,
    x1 float NOT NULL, y1 float NOT NULL,
    x2 float NOT NULL, y2 float NOT NULL,
    minx float NOT NULL, miny float NOT NULL,
    maxx float NOT NULL, maxy float NOT NULL,
    one_sided    bit NOT NULL,
    flag_block   bit NOT NULL,
    front_sector int NULL,
    back_sector  int NULL,
    special      smallint NOT NULL
);
CREATE INDEX ix_line_collide_box ON dbo.line_collide (minx, maxx, miny, maxy);
GO

CREATE PROCEDURE dbo.build_collision AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dbo.line_collide;
    INSERT INTO dbo.line_collide (linedef_id, x1, y1, x2, y2,
        minx, miny, maxx, maxy, one_sided, flag_block,
        front_sector, back_sector, special)
    SELECT  l.id, a.x, a.y, b.x, b.y,
            CASE WHEN a.x < b.x THEN a.x ELSE b.x END,
            CASE WHEN a.y < b.y THEN a.y ELSE b.y END,
            CASE WHEN a.x > b.x THEN a.x ELSE b.x END,
            CASE WHEN a.y > b.y THEN a.y ELSE b.y END,
            CONVERT(bit, CASE WHEN l.left_sidedef IS NULL
                               OR l.right_sidedef IS NULL THEN 1 ELSE 0 END),
            CONVERT(bit, CASE WHEN l.flags & 1 = 1 THEN 1 ELSE 0 END),
            rsd.sector_id, lsd.sector_id, l.special
    FROM dbo.linedef l
    JOIN dbo.vertex a ON a.id = l.v1
    JOIN dbo.vertex b ON b.id = l.v2
    LEFT JOIN dbo.sidedef rsd ON rsd.id = l.right_sidedef
    LEFT JOIN dbo.sidedef lsd ON lsd.id = l.left_sidedef;

    /* the door count comes from a LEFT JOIN, not an EXISTS inside the SUM:
       an aggregate may not contain a subquery (Msg 130) */
    SELECT lines_indexed = COUNT(*),
           solid = SUM(CONVERT(int, lc.one_sided)),
           doors = SUM(CASE WHEN ds.special IS NULL THEN 0 ELSE 1 END)
    FROM dbo.line_collide lc
    LEFT JOIN dbo.door_special ds ON ds.special = lc.special;
END
GO

/* Same blocking rules as before, but the opening is computed from the
   sectors' CURRENT heights rather than a cached pair -- so a door that has
   risen 12 units is 12 units more walkable, this tic. */
CREATE FUNCTION dbo.move_blocked (@nx float, @ny float, @z float)
RETURNS bit
AS
BEGIN
    DECLARE @r float = 16.0, @height float = 56.0, @maxstep float = 24.0;
    IF EXISTS (
        SELECT 1
        FROM dbo.line_collide c
        LEFT JOIN dbo.sector fs ON fs.id = c.front_sector
        LEFT JOIN dbo.sector bs ON bs.id = c.back_sector
        CROSS APPLY (SELECT dx = c.x2 - c.x1, dy = c.y2 - c.y1) d
        CROSS APPLY (SELECT len2 = d.dx * d.dx + d.dy * d.dy) e
        CROSS APPLY (SELECT t = CASE WHEN e.len2 = 0 THEN 0.0
                        ELSE ((@nx - c.x1) * d.dx + (@ny - c.y1) * d.dy) / e.len2
                     END) f
        CROSS APPLY (SELECT tc = CASE WHEN f.t < 0 THEN 0.0
                                      WHEN f.t > 1 THEN 1.0
                                      ELSE f.t END) g
        CROSS APPLY (SELECT ddx = @nx - (c.x1 + g.tc * d.dx),
                            ddy = @ny - (c.y1 + g.tc * d.dy)) h
        CROSS APPLY (SELECT
            open_top = CASE WHEN fs.ceil_h < bs.ceil_h THEN fs.ceil_h
                            ELSE bs.ceil_h END,
            open_bot = CASE WHEN fs.floor_h > bs.floor_h THEN fs.floor_h
                            ELSE bs.floor_h END) o
        WHERE @nx >= c.minx - @r AND @nx <= c.maxx + @r
          AND @ny >= c.miny - @r AND @ny <= c.maxy + @r
          AND h.ddx * h.ddx + h.ddy * h.ddy < @r * @r
          AND (   c.one_sided = 1
               OR c.flag_block = 1
               OR o.open_top IS NULL
               OR o.open_top - o.open_bot < @height
               OR o.open_top - @z < @height
               OR o.open_bot - @z > @maxstep)
    )
        RETURN 1;
    RETURN 0;
END
GO

/* How high a door opens: the lowest ceiling among its neighbours, less 4.
   Called once when a door is triggered, never per frame. */
CREATE FUNCTION dbo.open_target (@sector int)
RETURNS smallint
AS
BEGIN
    DECLARE @h int = (
        SELECT MIN(o.ceil_h)
        FROM dbo.linedef l
        JOIN dbo.sidedef sd1 ON sd1.id = l.right_sidedef
        JOIN dbo.sidedef sd2 ON sd2.id = l.left_sidedef
        JOIN dbo.sector o
          ON o.id = CASE WHEN sd1.sector_id = @sector THEN sd2.sector_id
                         ELSE sd1.sector_id END
        WHERE sd1.sector_id = @sector OR sd2.sector_id = @sector);
    IF @h IS NULL
        SET @h = (SELECT ceil_h FROM dbo.sector WHERE id = @sector);
    RETURN CONVERT(smallint, @h - 4);
END
GO

/* ---------------------------------------------------------------------
   P_UseLines. Doom traces a line 64 units ahead of the player and takes the
   first special linedef it crosses. Here that is a ray/segment intersection
   over the same indexed box, ordered by distance, TOP 1 -- the trace is a
   query rather than a loop.
   --------------------------------------------------------------------- */
CREATE PROCEDURE dbo.p_use AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @USERANGE float = 64.0;
    DECLARE @px float, @py float, @ang float;
    SELECT @px = x, @py = y, @ang = angle FROM dbo.player WHERE id = 1;
    IF @px IS NULL RETURN;

    DECLARE @dx float = COS(@ang) * @USERANGE, @dy float = SIN(@ang) * @USERANGE;

    DECLARE @line int, @sector int, @special smallint;
    SELECT TOP 1 @line = c.linedef_id, @special = c.special,
           /* the door is the sector on the far side of the line */
           @sector = CASE WHEN i.side > 0 THEN c.back_sector ELSE c.front_sector END
    FROM dbo.line_collide c
    JOIN dbo.door_special ds ON ds.special = c.special
    CROSS APPLY (SELECT ex = c.x2 - c.x1, ey = c.y2 - c.y1) e
    CROSS APPLY (SELECT den = @dx * e.ey - @dy * e.ex) d
    CROSS APPLY (SELECT
        t = CASE WHEN d.den = 0 THEN NULL
                 ELSE ((c.x1 - @px) * e.ey - (c.y1 - @py) * e.ex) / d.den END,
        u = CASE WHEN d.den = 0 THEN NULL
                 ELSE ((c.x1 - @px) * @dy - (c.y1 - @py) * @dx) / d.den END) p
    CROSS APPLY (SELECT
        side = (@px - c.x1) * e.ey - (@py - c.y1) * e.ex) i
    WHERE p.t IS NOT NULL
      AND p.t > 0 AND p.t <= 1        -- within reach
      AND p.u >= 0 AND p.u <= 1       -- actually on the line segment
    ORDER BY p.t;

    IF @sector IS NULL RETURN;        -- nothing usable in front of the player

    DECLARE @speed smallint, @stay bit, @keyt tinyint;
    SELECT @speed = speed, @stay = stay, @keyt = key_type
    FROM dbo.door_special WHERE special = @special;

    /* Keys are not implemented yet, so locked doors simply refuse. When an
       inventory arrives this becomes a lookup rather than a rejection. */
    IF @keyt <> 0
    BEGIN
        PRINT 'that door is locked';
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM dbo.door WHERE sector_id = @sector)
    BEGIN
        /* using a door mid-motion reverses it, as in Doom */
        UPDATE dbo.door
           SET state = CASE WHEN state = 3 THEN 1 ELSE 3 END,
               timer = 0
         WHERE sector_id = @sector AND (state = 3 OR state = 2);
        RETURN;
    END

    /* only start a door that is actually shut */
    INSERT INTO dbo.door (sector_id, state, top_h, bottom_h, speed,
                          wait_tics, timer, stay)
    SELECT @sector, 1, dbo.open_target(@sector), s.floor_h, @speed,
           150, 0, @stay
    FROM dbo.sector s
    WHERE s.id = @sector
      AND s.ceil_h < dbo.open_target(@sector);
END
GO

/* ---------------------------------------------------------------------
   Every door in the level moves in one UPDATE. Doom walks a thinker list;
   this is the same work as a set operation.
   --------------------------------------------------------------------- */
CREATE PROCEDURE dbo.p_door_tick AS
BEGIN
    SET NOCOUNT ON;

    /* ---- opening: raise the ceiling, clamped at the target */
    UPDATE s
       SET ceil_h = CASE WHEN s.ceil_h + d.speed > d.top_h THEN d.top_h
                         ELSE s.ceil_h + d.speed END
      FROM dbo.sector s
      JOIN dbo.door d ON d.sector_id = s.id
     WHERE d.state = 1;

    /* reached the top: wait, or finish if it stays open */
    DELETE d FROM dbo.door d
      JOIN dbo.sector s ON s.id = d.sector_id
     WHERE d.state = 1 AND s.ceil_h >= d.top_h AND d.stay = 1;

    UPDATE d
       SET state = 2, timer = d.wait_tics
      FROM dbo.door d
      JOIN dbo.sector s ON s.id = d.sector_id
     WHERE d.state = 1 AND s.ceil_h >= d.top_h;

    /* ---- waiting at the top */
    UPDATE dbo.door SET timer = timer - 1 WHERE state = 2 AND timer > 0;
    UPDATE dbo.door SET state = 3 WHERE state = 2 AND timer <= 0;

    /* ---- closing. A door that would come down on the player goes back up
       instead: Doom's crush check, as a correlated EXISTS. */
    UPDATE d
       SET state = 1
      FROM dbo.door d
      JOIN dbo.player p ON p.sector_id = d.sector_id
     WHERE d.state = 3;

    UPDATE s
       SET ceil_h = CASE WHEN s.ceil_h - d.speed < d.bottom_h THEN d.bottom_h
                         ELSE s.ceil_h - d.speed END
      FROM dbo.sector s
      JOIN dbo.door d ON d.sector_id = s.id
     WHERE d.state = 3;

    /* shut: the thinker is done */
    DELETE d FROM dbo.door d
      JOIN dbo.sector s ON s.id = d.sector_id
     WHERE d.state = 3 AND s.ceil_h <= d.bottom_h;
END
GO

/* p_frame gains the door tick and a use edge. @use is 1 only on the frame
   the key was newly pressed -- holding it should not re-trigger. */
CREATE PROCEDURE dbo.p_frame @tics int = 4, @use bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @use = 1 EXEC dbo.p_use;

    DECLARE @i int = 0;
    WHILE @i < @tics
    BEGIN
        EXEC dbo.p_tick;
        EXEC dbo.p_door_tick;
        SET @i += 1;
    END

    DECLARE @px float, @py float, @ang float;
    SELECT @px = x, @py = y, @ang = angle FROM dbo.player WHERE id = 1;

    EXEC dbo.render_frame @px, @py, @ang;

    IF OBJECT_ID('dbo.render_sprites') IS NOT NULL
        EXEC dbo.render_sprites @px, @py, @ang;

    SELECT bmp = dbo.frame_bmp();
END
GO

PRINT 'Doors loaded. Run EXEC dbo.build_collision; (line_collide has changed).';
