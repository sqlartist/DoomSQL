/* =====================================================================
   doom_weapons.sql -- stage 9. Picking things up, holding a gun, firing it.

   Run after doom_sky.sql, and reload the sprite data first: the weapon HUD
   sprites (PISG, PISF, SHTG...) are not map things, so nothing referenced
   them and the earlier extraction skipped them. Regenerated E1M1_sprites.sql
   now has 444 frames instead of 405.

   Nothing here touches p_frame. doom_sky.sql calls p_fire, p_weapon_tick,
   p_pickup and render_psprite behind OBJECT_ID guards, so this file just
   creates procedures with those names.

   THE PART WORTH READING is weapon_state. Doom's info.c is a giant static
   array of states, each holding a sprite, a frame, a duration in tics, and a
   pointer to the next one -- a table pretending to be C. Here it is a table,
   and advancing every animation in the game is one UPDATE joined to it.
   ===================================================================== */

IF OBJECT_ID('dbo.render_psprite')  IS NOT NULL DROP PROCEDURE dbo.render_psprite;
IF OBJECT_ID('dbo.p_weapon_tick')   IS NOT NULL DROP PROCEDURE dbo.p_weapon_tick;
IF OBJECT_ID('dbo.p_fire')          IS NOT NULL DROP PROCEDURE dbo.p_fire;
IF OBJECT_ID('dbo.p_pickup')        IS NOT NULL DROP PROCEDURE dbo.p_pickup;
IF OBJECT_ID('dbo.setup_player')    IS NOT NULL DROP PROCEDURE dbo.setup_player;
GO
IF OBJECT_ID('dbo.psprite')       IS NOT NULL DROP TABLE dbo.psprite;
IF OBJECT_ID('dbo.weapon_state')  IS NOT NULL DROP TABLE dbo.weapon_state;
IF OBJECT_ID('dbo.weapon')        IS NOT NULL DROP TABLE dbo.weapon;
IF OBJECT_ID('dbo.pickup')        IS NOT NULL DROP TABLE dbo.pickup;
IF OBJECT_ID('dbo.death_type')    IS NOT NULL DROP TABLE dbo.death_type;
IF OBJECT_ID('dbo.thing_health')  IS NOT NULL DROP TABLE dbo.thing_health;
IF OBJECT_ID('dbo.inventory')     IS NOT NULL DROP TABLE dbo.inventory;
GO

CREATE TABLE dbo.inventory (
    id        tinyint NOT NULL PRIMARY KEY DEFAULT 1,
    health    int NOT NULL DEFAULT 100,
    armour    int NOT NULL DEFAULT 0,
    bullets   int NOT NULL DEFAULT 50,
    shells    int NOT NULL DEFAULT 0,
    rockets   int NOT NULL DEFAULT 0,
    cells     int NOT NULL DEFAULT 0,
    weapons   int NOT NULL DEFAULT 3,   -- bitmask: 1 fist, 2 pistol, 4 shotgun...
    /* not `current`, and not `bit` in dbo.weapon: both are reserved words in
       T-SQL and fail at CREATE with Msg 156. */
    cur_weapon tinyint NOT NULL DEFAULT 2   -- 2 = pistol, not 1 = fist
);

CREATE TABLE dbo.weapon (
    id        tinyint NOT NULL PRIMARY KEY,
    name      varchar(16) NOT NULL,
    weapon_bit int NOT NULL,
    ammo      varchar(8) NULL,          -- NULL for the fist
    per_shot  int NOT NULL,
    damage    int NOT NULL,
    pellets   int NOT NULL,             -- shotgun fires several
    range_    int NOT NULL
);
INSERT INTO dbo.weapon (id, name, weapon_bit, ammo, per_shot, damage, pellets, range_) VALUES
    (1, 'fist',    1,  NULL,      0,  10, 1,   64),
    (2, 'pistol',  2,  'bullets', 1,  15, 1, 2048),
    (3, 'shotgun', 4,  'shells',  1,  15, 7, 2048),
    (4, 'chaingun',8,  'bullets', 1,  15, 1, 2048);

/* info.c, as data. seq is the position in the animation; next_seq is the
   pointer; action is what fires when the state is entered. */
CREATE TABLE dbo.weapon_state (
    weapon_id tinyint NOT NULL,
    seq       tinyint NOT NULL,
    sprite    char(4) NOT NULL,
    frame     char(1) NOT NULL,
    tics      int NOT NULL,             -- -1 means stay here (ready)
    next_seq  tinyint NOT NULL,
    action    varchar(8) NULL,          -- 'fire' does the hitscan
    flash     char(1) NULL,             -- muzzle flash frame, if any
    CONSTRAINT pk_weapon_state PRIMARY KEY (weapon_id, seq)
);
INSERT INTO dbo.weapon_state
    (weapon_id, seq, sprite, frame, tics, next_seq, action, flash) VALUES
    -- fist
    (1, 0, 'PUNG', 'A', -1, 0, NULL,   NULL),
    (1, 1, 'PUNG', 'B',  4, 2, NULL,   NULL),
    (1, 2, 'PUNG', 'C',  4, 3, 'fire', NULL),
    (1, 3, 'PUNG', 'D',  5, 4, NULL,   NULL),
    (1, 4, 'PUNG', 'C',  4, 0, NULL,   NULL),
    -- pistol
    (2, 0, 'PISG', 'A', -1, 0, NULL,   NULL),
    (2, 1, 'PISG', 'A',  4, 2, NULL,   NULL),
    (2, 2, 'PISG', 'B',  6, 3, 'fire', 'A'),
    (2, 3, 'PISG', 'C',  4, 4, NULL,   NULL),
    (2, 4, 'PISG', 'B',  5, 0, NULL,   NULL),
    -- shotgun
    (3, 0, 'SHTG', 'A', -1, 0, NULL,   NULL),
    (3, 1, 'SHTG', 'A',  3, 2, NULL,   NULL),
    (3, 2, 'SHTG', 'A',  7, 3, 'fire', 'A'),
    (3, 3, 'SHTG', 'B',  5, 4, NULL,   NULL),
    (3, 4, 'SHTG', 'C',  5, 5, NULL,   NULL),
    (3, 5, 'SHTG', 'D',  4, 6, NULL,   NULL),
    (3, 6, 'SHTG', 'C',  5, 7, NULL,   NULL),
    (3, 7, 'SHTG', 'B',  5, 0, NULL,   NULL),
    -- chaingun
    (4, 0, 'CHGG', 'A', -1, 0, NULL,   NULL),
    (4, 1, 'CHGG', 'A',  4, 2, 'fire', 'A'),
    (4, 2, 'CHGG', 'B',  4, 0, 'fire', 'B');

/* What the player is currently holding, and where in the animation. */
CREATE TABLE dbo.psprite (
    id          tinyint NOT NULL PRIMARY KEY DEFAULT 1,
    weapon_id   tinyint NOT NULL,
    seq         tinyint NOT NULL,
    tics        int NOT NULL,
    flash_frame char(1) NULL,
    flash_tics  int NOT NULL DEFAULT 0
);

/* doomednum -> what collecting it does. */
CREATE TABLE dbo.pickup (
    doomednum int NOT NULL PRIMARY KEY,
    kind      varchar(8) NOT NULL,      -- health/armour/ammo/weapon
    field     varchar(8) NULL,
    amount    int NOT NULL,
    weapon_id tinyint NULL,
    cap       int NOT NULL,
    descr     varchar(24) NOT NULL
);
INSERT INTO dbo.pickup (doomednum, kind, field, amount, weapon_id, cap, descr) VALUES
    (2011,'health','health',  10, NULL, 100, 'stimpack'),
    (2012,'health','health',  25, NULL, 100, 'medikit'),
    (2014,'health','health',   1, NULL, 200, 'health bonus'),
    (2015,'armour','armour',   1, NULL, 200, 'armour bonus'),
    (2018,'armour','armour', 100, NULL, 100, 'armour'),
    (2019,'armour','armour', 200, NULL, 200, 'megaarmour'),
    (2007,'ammo',  'bullets', 10, NULL, 200, 'clip'),
    (2048,'ammo',  'bullets', 50, NULL, 200, 'box of bullets'),
    (2008,'ammo',  'shells',   4, NULL,  50, 'shells'),
    (2049,'ammo',  'shells',  20, NULL,  50, 'box of shells'),
    (2010,'ammo',  'rockets',  1, NULL,  50, 'rocket'),
    (2046,'ammo',  'rockets',  5, NULL,  50, 'box of rockets'),
    (2047,'ammo',  'cells',   20, NULL, 300, 'cell'),
    (17,  'ammo',  'cells',  100, NULL, 300, 'cell pack'),
    (2001,'weapon','shells',   8,    3,  50, 'shotgun'),
    (2002,'weapon','bullets', 20,    4, 200, 'chaingun'),
    (8,   'ammo',  'bullets',  0, NULL, 200, 'backpack');

/* Monsters that die become their corpse thing -- which is already in
   mobj_type, so the sprite pass needs no change at all. */
CREATE TABLE dbo.death_type (
    doomednum      int NOT NULL PRIMARY KEY,
    corpse_num     int NOT NULL,
    health         int NOT NULL,
    descr          varchar(20) NOT NULL
);
INSERT INTO dbo.death_type (doomednum, corpse_num, health, descr) VALUES
    (3004, 18,  20, 'zombieman'),
    (9,    19,  30, 'shotgun guy'),
    (3001, 20,  60, 'imp'),
    (3002, 21, 150, 'demon'),
    (58,   21, 150, 'spectre'),
    (3005, 22, 400, 'cacodemon'),
    (3006, 23, 100, 'lost soul'),
    (2035, 24,  20, 'barrel');

CREATE TABLE dbo.thing_health (
    thing_id int NOT NULL PRIMARY KEY,
    health   int NOT NULL
);
GO

CREATE PROCEDURE dbo.setup_player AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.inventory;
    /* explicit rather than relying on defaults: cur_weapon must match the
       psprite below, or p_pickup's weapon-changed UPDATE will yank the player
       back to whatever inventory says on the very first tic. */
    INSERT INTO dbo.inventory (id, health, weapons, cur_weapon)
    VALUES (1, 100, 3, 2);                         -- fist + pistol, holding pistol
    DELETE FROM dbo.psprite;
    INSERT INTO dbo.psprite (id, weapon_id, seq, tics) VALUES (1, 2, 0, -1);

    /* every monster gets its starting health */
    TRUNCATE TABLE dbo.thing_health;
    INSERT INTO dbo.thing_health (thing_id, health)
    SELECT t.id, d.health
    FROM dbo.thing t JOIN dbo.death_type d ON d.doomednum = t.type;

    SELECT * FROM dbo.inventory;
END
GO

/* ---------------------------------------------------------------------
   Pickups. Everything the player is standing on, collected in one pass:
   the effects are joins, not a switch statement.
   --------------------------------------------------------------------- */
CREATE PROCEDURE dbo.p_pickup AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @reach float = 36.0;        -- player radius 16 + item radius 20

    DECLARE @got TABLE (thing_id int, doomednum int);
    INSERT INTO @got (thing_id, doomednum)
    SELECT t.id, t.type
    FROM dbo.thing t
    JOIN dbo.pickup pk ON pk.doomednum = t.type
    CROSS JOIN dbo.player p
    WHERE p.id = 1
      AND (t.x - p.x) * (t.x - p.x) + (t.y - p.y) * (t.y - p.y)
          < @reach * @reach;

    IF NOT EXISTS (SELECT 1 FROM @got) RETURN;

    /* health and armour, capped */
    UPDATE inv
       SET health = CASE WHEN inv.health + a.hp > a.hpcap THEN a.hpcap
                         ELSE inv.health + a.hp END,
           armour = CASE WHEN inv.armour + a.ar > a.arcap THEN a.arcap
                         ELSE inv.armour + a.ar END
      FROM dbo.inventory inv
      CROSS APPLY (
        SELECT hp    = COALESCE(SUM(CASE WHEN pk.kind = 'health' THEN pk.amount END), 0),
               hpcap = COALESCE(MAX(CASE WHEN pk.kind = 'health' THEN pk.cap END), 200),
               ar    = COALESCE(SUM(CASE WHEN pk.kind = 'armour' THEN pk.amount END), 0),
               arcap = COALESCE(MAX(CASE WHEN pk.kind = 'armour' THEN pk.cap END), 200)
        FROM @got g JOIN dbo.pickup pk ON pk.doomednum = g.doomednum) a
     WHERE inv.id = 1;

    /* ammo, by field, capped */
    UPDATE inv
       SET bullets = CASE WHEN inv.bullets + a.b > 200 THEN 200 ELSE inv.bullets + a.b END,
           shells  = CASE WHEN inv.shells  + a.s > 50  THEN 50  ELSE inv.shells  + a.s END,
           rockets = CASE WHEN inv.rockets + a.r > 50  THEN 50  ELSE inv.rockets + a.r END,
           cells   = CASE WHEN inv.cells   + a.c > 300 THEN 300 ELSE inv.cells   + a.c END
      FROM dbo.inventory inv
      CROSS APPLY (
        SELECT b = COALESCE(SUM(CASE WHEN pk.field = 'bullets' THEN pk.amount END), 0),
               s = COALESCE(SUM(CASE WHEN pk.field = 'shells'  THEN pk.amount END), 0),
               r = COALESCE(SUM(CASE WHEN pk.field = 'rockets' THEN pk.amount END), 0),
               c = COALESCE(SUM(CASE WHEN pk.field = 'cells'   THEN pk.amount END), 0)
        FROM @got g JOIN dbo.pickup pk ON pk.doomednum = g.doomednum
        WHERE pk.kind IN ('ammo','weapon')) a
     WHERE inv.id = 1;

    /* weapons: OR the bits in, and switch to the best new one */
    UPDATE inv
       SET weapons = inv.weapons | a.bits,
           cur_weapon = CASE WHEN a.best IS NULL THEN inv.cur_weapon ELSE a.best END
      FROM dbo.inventory inv
      CROSS APPLY (
        SELECT bits = COALESCE(SUM(DISTINCT w.weapon_bit), 0),
               best = MAX(w.id)
        FROM @got g
        JOIN dbo.pickup pk ON pk.doomednum = g.doomednum AND pk.kind = 'weapon'
        JOIN dbo.weapon w  ON w.id = pk.weapon_id) a
     WHERE inv.id = 1;

    /* switching weapon resets the animation */
    UPDATE ps
       SET weapon_id = inv.cur_weapon, seq = 0, tics = -1
      FROM dbo.psprite ps
      JOIN dbo.inventory inv ON inv.id = 1
     WHERE ps.weapon_id <> inv.cur_weapon;

    /* the items leave the world */
    DELETE t FROM dbo.thing t JOIN @got g ON g.thing_id = t.id;
    DELETE ts FROM dbo.thing_sector ts JOIN @got g ON g.thing_id = ts.thing_id;
END
GO

/* ---------------------------------------------------------------------
   Pulling the trigger only starts the animation. The shot itself happens
   when the animation reaches the state whose action is 'fire' -- which is
   how Doom works, and why the muzzle flash lines up with the bang.
   --------------------------------------------------------------------- */
CREATE PROCEDURE dbo.p_fire AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @w tinyint, @seq tinyint, @ammo varchar(8), @need int;
    SELECT @w = ps.weapon_id, @seq = ps.seq FROM dbo.psprite ps WHERE ps.id = 1;
    IF @seq <> 0 RETURN;                       -- already mid-animation

    SELECT @ammo = w.ammo, @need = w.per_shot FROM dbo.weapon w WHERE w.id = @w;

    IF @ammo IS NOT NULL
    BEGIN
        DECLARE @have int = (SELECT CASE @ammo
                                WHEN 'bullets' THEN bullets
                                WHEN 'shells'  THEN shells
                                WHEN 'rockets' THEN rockets
                                WHEN 'cells'   THEN cells END
                             FROM dbo.inventory WHERE id = 1);
        IF @have < @need RETURN;               -- click
    END

    UPDATE dbo.psprite SET seq = 1, tics =
        (SELECT tics FROM dbo.weapon_state WHERE weapon_id = @w AND seq = 1)
    WHERE id = 1;
END
GO

/* ---------------------------------------------------------------------
   One tic of the weapon: advance the animation, and if the state we land in
   says 'fire', spend the ammo and trace the shot.

   The hitscan is the interesting query. Doom walks a blockmap trace; here it
   is: every monster within range and within the aim cone, ordered by
   distance, minus any that has a solid wall between it and the player.
   --------------------------------------------------------------------- */
CREATE PROCEDURE dbo.p_weapon_tick AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.psprite SET tics = tics - 1 WHERE tics > 0;
    UPDATE dbo.psprite SET flash_tics = flash_tics - 1 WHERE flash_tics > 0;
    UPDATE dbo.psprite SET flash_frame = NULL WHERE flash_tics <= 0;

    IF NOT EXISTS (SELECT 1 FROM dbo.psprite WHERE tics = 0) RETURN;

    /* advance to the next state */
    UPDATE ps
       SET seq = st.next_seq,
           tics = nxt.tics,
           flash_frame = COALESCE(nxt.flash, ps.flash_frame),
           flash_tics = CASE WHEN nxt.flash IS NOT NULL THEN 5 ELSE ps.flash_tics END
      FROM dbo.psprite ps
      JOIN dbo.weapon_state st  ON st.weapon_id = ps.weapon_id AND st.seq = ps.seq
      JOIN dbo.weapon_state nxt ON nxt.weapon_id = ps.weapon_id
                              AND nxt.seq = st.next_seq
     WHERE ps.tics = 0;

    /* did we just enter a firing state? */
    DECLARE @fire bit = 0, @w tinyint;
    SELECT @fire = CASE WHEN st.action = 'fire' THEN 1 ELSE 0 END,
           @w = ps.weapon_id
    FROM dbo.psprite ps
    JOIN dbo.weapon_state st ON st.weapon_id = ps.weapon_id AND st.seq = ps.seq
    WHERE ps.id = 1;

    IF @fire = 0 RETURN;

    /* ---- spend the ammo */
    DECLARE @ammo varchar(8), @cost int, @dmg int, @pellets int, @rng int;
    SELECT @ammo = ammo, @cost = per_shot, @dmg = damage,
           @pellets = pellets, @rng = range_
    FROM dbo.weapon WHERE id = @w;

    UPDATE dbo.inventory
       SET bullets = bullets - CASE WHEN @ammo = 'bullets' THEN @cost ELSE 0 END,
           shells  = shells  - CASE WHEN @ammo = 'shells'  THEN @cost ELSE 0 END,
           rockets = rockets - CASE WHEN @ammo = 'rockets' THEN @cost ELSE 0 END,
           cells   = cells   - CASE WHEN @ammo = 'cells'   THEN @cost ELSE 0 END
     WHERE id = 1;

    /* ---- the hitscan */
    DECLARE @px float, @py float, @ang float;
    SELECT @px = x, @py = y, @ang = angle FROM dbo.player WHERE id = 1;

    DECLARE @target int;
    ;WITH cand AS (
        SELECT  t.id,
                dist = SQRT(SQUARE(t.x - @px) + SQUARE(t.y - @py)),
                /* angle from the player to the thing, relative to the aim,
                   normalised into [-180,180) without integer modulo */
                rel = r.raw - 360.0 * FLOOR((r.raw + 180.0) / 360.0)
        FROM dbo.thing t
        JOIN dbo.thing_health th ON th.thing_id = t.id AND th.health > 0
        CROSS APPLY (SELECT raw = DEGREES(ATN2(t.y - @py, t.x - @px))
                               - DEGREES(@ang)) r
    ),
    inrange AS (
        SELECT c.id, c.dist
        FROM cand c
        WHERE c.dist <= @rng AND c.dist > 0
          /* aim cone: wider up close, tighter far away, which is roughly
             what Doom's autoaim feels like */
          AND ABS(c.rel) < CASE WHEN c.dist < 128 THEN 30.0 ELSE 8.0 END
    ),
    unblocked AS (
        SELECT TOP 1 i.id, i.dist
        FROM inrange i
        WHERE NOT EXISTS (
            /* any one-sided wall crossing the line of fire, nearer than the
               target, blocks the shot */
            SELECT 1
            FROM dbo.line_collide lc
            JOIN dbo.thing tt ON tt.id = i.id
            CROSS APPLY (SELECT ex = lc.x2 - lc.x1, ey = lc.y2 - lc.y1) e
            CROSS APPLY (SELECT dx = tt.x - @px, dy = tt.y - @py) d
            CROSS APPLY (SELECT den = d.dx * e.ey - d.dy * e.ex) q
            CROSS APPLY (SELECT
                t1 = CASE WHEN q.den = 0 THEN NULL
                          ELSE ((lc.x1 - @px) * e.ey - (lc.y1 - @py) * e.ex) / q.den END,
                u1 = CASE WHEN q.den = 0 THEN NULL
                          ELSE ((lc.x1 - @px) * d.dy - (lc.y1 - @py) * d.dx) / q.den END) p
            WHERE lc.one_sided = 1
              AND p.t1 IS NOT NULL
              AND p.t1 > 0.001 AND p.t1 < 1
              AND p.u1 >= 0 AND p.u1 <= 1)
        ORDER BY i.dist
    )
    SELECT @target = id FROM unblocked;

    IF @target IS NULL RETURN;

    UPDATE dbo.thing_health
       SET health = health - @dmg * @pellets
     WHERE thing_id = @target;

    /* dead things become their corpse. mobj_type already knows what a corpse
       looks like, so the sprite pass needs no change whatsoever. */
    UPDATE t
       SET type = d.corpse_num
      FROM dbo.thing t
      JOIN dbo.thing_health th ON th.thing_id = t.id
      JOIN dbo.death_type d ON d.doomednum = t.type
     WHERE t.id = @target AND th.health <= 0;

    DELETE th FROM dbo.thing_health th
     WHERE th.thing_id = @target AND th.health <= 0;
END
GO

/* ---------------------------------------------------------------------
   The weapon on screen. Psprites are not world geometry: no depth, no
   perspective, drawn 1:1 at 320x200. Doom positions them from the patch
   offsets, which for weapons are large and negative -- PISGA0 has left -125
   and top -97, giving x = 1 - (-125) = 126 and y = 32 - (-97) = 129. The
   sprite runs off the bottom of the screen, which is exactly right.
   --------------------------------------------------------------------- */
CREATE PROCEDURE dbo.render_psprite AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @W int = 320, @H int = 200;
    DECLARE @PSP_SX int = 1, @PSP_SY int = 32;     -- WEAPONTOP

    ;WITH shown AS (
        /* the weapon itself, and its muzzle flash if one is lit */
        SELECT sf.id AS frame_id, sf.width, sf.height,
               sf.left_off, sf.top_off, layer = 0
        FROM dbo.psprite ps
        JOIN dbo.weapon_state st ON st.weapon_id = ps.weapon_id AND st.seq = ps.seq
        JOIN dbo.sprite_frame sf ON sf.sprite = st.sprite
                                AND sf.frame = st.frame AND sf.rotation = 0
        WHERE ps.id = 1
        UNION ALL
        SELECT sf.id, sf.width, sf.height, sf.left_off, sf.top_off, 1
        FROM dbo.psprite ps
        JOIN dbo.weapon_state st ON st.weapon_id = ps.weapon_id AND st.seq = ps.seq
        JOIN dbo.sprite_frame sf
          ON sf.sprite = LEFT(st.sprite, 3) + 'F'   -- PISG -> PISF
         AND sf.frame = ps.flash_frame AND sf.rotation = 0
        WHERE ps.id = 1 AND ps.flash_frame IS NOT NULL
    ),
    placed AS (
        SELECT s.*, x0 = @PSP_SX - s.left_off, y0 = @PSP_SY - s.top_off
        FROM shown s
    ),
    px AS (
        SELECT p.frame_id, p.layer,
               x = CONVERT(smallint, nx.n), y = CONVERT(smallint, ny.n),
               u = nx.n - p.x0, v = ny.n - p.y0
        FROM placed p
        JOIN dbo.numbers nx ON nx.n >= p.x0 AND nx.n < p.x0 + p.width
                           AND nx.n >= 0 AND nx.n < @W
        JOIN dbo.numbers ny ON ny.n >= p.y0 AND ny.n < p.y0 + p.height
                           AND ny.n >= 0 AND ny.n < @H
    ),
    sampled AS (
        SELECT p.x, p.y, p.layer,
               pal_idx = CONVERT(tinyint, SUBSTRING(sc.pixels, p.v + 1, 1))
        FROM px p
        JOIN dbo.sprite_column sc
          ON sc.frame_id = p.frame_id AND sc.u = p.u
        WHERE sc.alpha IS NULL
           OR CONVERT(tinyint, SUBSTRING(sc.alpha, p.v + 1, 1)) = 1
    ),
    winner AS (
        SELECT x, y, pal_idx,
               rn = ROW_NUMBER() OVER (PARTITION BY x, y ORDER BY layer DESC)
        FROM sampled
    )
    SELECT x, y, pal_idx INTO #psp FROM winner WHERE rn = 1;

    DELETE fb FROM dbo.framebuffer fb JOIN #psp s ON s.x = fb.x AND s.y = fb.y;
    INSERT INTO dbo.framebuffer (x, y, pal_idx, light)
    SELECT x, y, pal_idx, 0 FROM #psp;      -- the weapon is full bright
    DROP TABLE #psp;
END
GO

/* ---------------------------------------------------------------------
   Weapon selection. There was no way to change weapon at all before this --
   an omission, not a bug in something else.
   --------------------------------------------------------------------- */
IF OBJECT_ID('dbo.p_select_weapon') IS NOT NULL DROP PROCEDURE dbo.p_select_weapon;
GO

CREATE PROCEDURE dbo.p_select_weapon @slot tinyint
AS
BEGIN
    SET NOCOUNT ON;
    /* only if it is owned, and not while an animation is running */
    IF NOT EXISTS (
        SELECT 1 FROM dbo.inventory inv
        JOIN dbo.weapon w ON w.id = @slot
        WHERE inv.id = 1 AND inv.weapons & w.weapon_bit <> 0)
        RETURN;
    IF EXISTS (SELECT 1 FROM dbo.psprite WHERE id = 1 AND seq <> 0) RETURN;

    UPDATE dbo.inventory SET cur_weapon = @slot WHERE id = 1;
    UPDATE dbo.psprite SET weapon_id = @slot, seq = 0, tics = -1,
                           flash_frame = NULL, flash_tics = 0
     WHERE id = 1;
END
GO

PRINT 'Weapons loaded. Run EXEC dbo.setup_player;';
