/* =====================================================================
   doom_reset.sql -- put the level back how it started.

   Run after doom_weapons.sql.

   WHY THIS IS NEEDED. The game mutates the level in place and keeps no
   record of what it looked like before:

     - killing something UPDATEs dbo.thing.type to its corpse number
     - collecting something DELETEs the row entirely
     - opening a door UPDATEs dbo.sector.ceil_h

   That is fine for playing and useless for restarting. So take a snapshot
   of the two tables the game writes to, once, while the level is pristine,
   and restoring becomes two statements instead of reloading 3.8 MB.

   IMPORTANT: snapshot a CLEAN level. If you have already been playing,
   re-run E1M1_freedoom.sql first -- it rebuilds dbo.thing and dbo.sector
   from the WAD -- and then snapshot. snapshot_level prints a monster count
   so you can tell at a glance whether you captured a fresh level or a
   graveyard.

   A note on why this is not done by reverse-mapping corpses back to
   monsters, which would avoid the reload: it cannot be made correct. Two
   different monsters share a corpse type, and several corpse types are also
   legitimate scenery that the mapper placed as corpses in the first place.
   There is no way to tell "dead imp" from "decorative body that has always
   been there" after the fact. Snapshotting sidesteps the ambiguity.
   ===================================================================== */

IF OBJECT_ID('dbo.reset_level')     IS NOT NULL DROP PROCEDURE dbo.reset_level;
IF OBJECT_ID('dbo.snapshot_level')  IS NOT NULL DROP PROCEDURE dbo.snapshot_level;
GO
IF OBJECT_ID('dbo.sector_spawn') IS NOT NULL DROP TABLE dbo.sector_spawn;
IF OBJECT_ID('dbo.thing_spawn')  IS NOT NULL DROP TABLE dbo.thing_spawn;
GO

CREATE TABLE dbo.thing_spawn (
    id    int NOT NULL PRIMARY KEY,
    x     smallint NOT NULL,
    y     smallint NOT NULL,
    angle smallint NOT NULL,
    type  smallint NOT NULL,
    flags smallint NOT NULL
);

/* only the heights move; the flats and light never change */
CREATE TABLE dbo.sector_spawn (
    id      int NOT NULL PRIMARY KEY,
    floor_h smallint NOT NULL,
    ceil_h  smallint NOT NULL
);
GO

CREATE PROCEDURE dbo.snapshot_level AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dbo.thing_spawn;
    TRUNCATE TABLE dbo.sector_spawn;

    INSERT INTO dbo.thing_spawn (id, x, y, angle, type, flags)
    SELECT id, x, y, angle, type, flags FROM dbo.thing;

    INSERT INTO dbo.sector_spawn (id, floor_h, ceil_h)
    SELECT id, floor_h, ceil_h FROM dbo.sector;

    /* a sanity read-out: if `monsters` looks low and `corpses` high, you have
       snapshotted a level you already cleared. Reload E1M1_freedoom.sql. */
    SELECT things   = (SELECT COUNT(*) FROM dbo.thing_spawn),
           sectors  = (SELECT COUNT(*) FROM dbo.sector_spawn),
           monsters = (SELECT COUNT(*) FROM dbo.thing_spawn ts
                       JOIN dbo.death_type d ON d.doomednum = ts.type),
           corpses  = (SELECT COUNT(*) FROM dbo.thing_spawn ts
                       JOIN dbo.death_type d ON d.corpse_num = ts.type),
           pickups  = (SELECT COUNT(*) FROM dbo.thing_spawn ts
                       JOIN dbo.pickup p ON p.doomednum = ts.type);
END
GO

CREATE PROCEDURE dbo.reset_level
    @keep_position bit = 0      -- 1 = restock the level but stay where you are
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.thing_spawn)
    BEGIN
        PRINT 'No snapshot. Run EXEC dbo.snapshot_level on a clean level first.';
        RETURN;
    END

    /* ---- the world */
    DELETE FROM dbo.thing;
    INSERT INTO dbo.thing (id, x, y, angle, type, flags)
    SELECT id, x, y, angle, type, flags FROM dbo.thing_spawn;

    UPDATE s SET floor_h = sp.floor_h, ceil_h = sp.ceil_h
      FROM dbo.sector s JOIN dbo.sector_spawn sp ON sp.id = s.id;

    DELETE FROM dbo.door;                    -- nothing is mid-motion any more

    /* ---- the caches that depend on the world */
    IF OBJECT_ID('dbo.build_thing_sector') IS NOT NULL
        EXEC dbo.build_thing_sector;

    /* ---- the player */
    IF @keep_position = 0 AND OBJECT_ID('dbo.setup_game') IS NOT NULL
        EXEC dbo.setup_game;                 -- back to the player 1 start

    IF OBJECT_ID('dbo.setup_player') IS NOT NULL
        EXEC dbo.setup_player;               -- health, ammo, and monster health

    SELECT things_restored = (SELECT COUNT(*) FROM dbo.thing),
           monsters_alive  = (SELECT COUNT(*) FROM dbo.thing_health
                              WHERE health > 0),
           doors_cleared   = (SELECT COUNT(*) FROM dbo.door);
END
GO

PRINT 'Reset loaded. On a CLEAN level run: EXEC dbo.snapshot_level;';
PRINT 'After that, EXEC dbo.reset_level; restocks it instantly.';
