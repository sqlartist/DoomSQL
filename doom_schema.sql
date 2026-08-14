/* =====================================================================
   doom_schema.sql -- a Doom level as a SQL Server database.

   id Software shipped a normalised schema in 1993 and called it a WAD.
   This is that schema, written out longhand, with the integer offsets
   turned into real foreign keys.

   Targets SQL Server 2016+ (spatial types, recursive CTEs).
   Run this, then run the generated <MAP>.sql to load data.
   ===================================================================== */

IF OBJECT_ID('dbo.bsp_order')        IS NOT NULL DROP FUNCTION dbo.bsp_order;
IF OBJECT_ID('dbo.wad_validate')     IS NOT NULL DROP PROCEDURE dbo.wad_validate;
IF OBJECT_ID('dbo.v_map_plan')       IS NOT NULL DROP VIEW dbo.v_map_plan;
IF OBJECT_ID('dbo.v_subsector')      IS NOT NULL DROP VIEW dbo.v_subsector;
GO
IF OBJECT_ID('dbo.seg_sector') IS NOT NULL DROP TABLE dbo.seg_sector;
IF OBJECT_ID('dbo.colormap')   IS NOT NULL DROP TABLE dbo.colormap;
IF OBJECT_ID('dbo.playpal')    IS NOT NULL DROP TABLE dbo.playpal;
IF OBJECT_ID('dbo.thing')      IS NOT NULL DROP TABLE dbo.thing;
IF OBJECT_ID('dbo.node')       IS NOT NULL DROP TABLE dbo.node;
IF OBJECT_ID('dbo.subsector')  IS NOT NULL DROP TABLE dbo.subsector;
IF OBJECT_ID('dbo.seg')        IS NOT NULL DROP TABLE dbo.seg;
IF OBJECT_ID('dbo.linedef')    IS NOT NULL DROP TABLE dbo.linedef;
IF OBJECT_ID('dbo.sidedef')    IS NOT NULL DROP TABLE dbo.sidedef;
IF OBJECT_ID('dbo.sector')     IS NOT NULL DROP TABLE dbo.sector;
IF OBJECT_ID('dbo.vertex')     IS NOT NULL DROP TABLE dbo.vertex;
IF OBJECT_ID('dbo.child_slot') IS NOT NULL DROP TABLE dbo.child_slot;
IF OBJECT_ID('dbo.map_meta')   IS NOT NULL DROP TABLE dbo.map_meta;
GO

CREATE TABLE dbo.map_meta (
    map_name    varchar(16) NOT NULL,
    source_wad  varchar(64) NOT NULL,
    loaded_at   datetime2   NOT NULL DEFAULT SYSUTCDATETIME()
);

/* Two rows. Exists so the recursive BSP walk can visit both children of a
   node with a plain INNER JOIN -- recursive members won't take a subquery. */
CREATE TABLE dbo.child_slot (ord tinyint NOT NULL PRIMARY KEY);
INSERT INTO dbo.child_slot (ord) VALUES (0), (1);   -- 0 = near, 1 = far
GO

CREATE TABLE dbo.vertex (
    id  int      NOT NULL PRIMARY KEY,
    x   smallint NOT NULL,
    y   smallint NOT NULL
);

CREATE TABLE dbo.sector (
    id         int      NOT NULL PRIMARY KEY,
    floor_h    smallint NOT NULL,
    ceil_h     smallint NOT NULL,
    floor_tex  varchar(8) NOT NULL,
    ceil_tex   varchar(8) NOT NULL,
    light      smallint NOT NULL,   -- 0..255, joins to colormap.light_level/8
    special    smallint NOT NULL,
    tag        smallint NOT NULL
);

CREATE TABLE dbo.sidedef (
    id          int NOT NULL PRIMARY KEY,
    x_off       smallint NOT NULL,
    y_off       smallint NOT NULL,
    upper_tex   varchar(8) NOT NULL,   -- '-' means no texture
    lower_tex   varchar(8) NOT NULL,
    middle_tex  varchar(8) NOT NULL,
    sector_id   int NOT NULL REFERENCES dbo.sector(id)
);
CREATE INDEX ix_sidedef_sector ON dbo.sidedef(sector_id);

CREATE TABLE dbo.linedef (
    id             int NOT NULL PRIMARY KEY,
    v1             int NOT NULL REFERENCES dbo.vertex(id),
    v2             int NOT NULL REFERENCES dbo.vertex(id),
    flags          smallint NOT NULL,
    special        smallint NOT NULL,
    tag            smallint NOT NULL,
    right_sidedef  int NULL REFERENCES dbo.sidedef(id),
    left_sidedef   int NULL REFERENCES dbo.sidedef(id)   -- NULL => solid wall
);

CREATE TABLE dbo.seg (
    id          int NOT NULL PRIMARY KEY,
    v1          int NOT NULL REFERENCES dbo.vertex(id),
    v2          int NOT NULL REFERENCES dbo.vertex(id),
    angle       smallint NOT NULL,    -- BAM: 0..65535 mapped to signed 16-bit
    linedef_id  int NOT NULL REFERENCES dbo.linedef(id),
    side        smallint NOT NULL,    -- 0 = right/front, 1 = left/back
    offset_u    smallint NOT NULL     -- texture u at seg start
);
CREATE INDEX ix_seg_linedef ON dbo.seg(linedef_id);

CREATE TABLE dbo.subsector (
    id         int NOT NULL PRIMARY KEY,
    first_seg  int NOT NULL,
    last_seg   int NOT NULL,
    seg_count  int NOT NULL
);

CREATE TABLE dbo.node (
    id        int NOT NULL PRIMARY KEY,
    part_x    smallint NOT NULL,   -- partition line origin
    part_y    smallint NOT NULL,
    part_dx   smallint NOT NULL,   -- and direction vector
    part_dy   smallint NOT NULL,
    r_top smallint NOT NULL, r_bottom smallint NOT NULL,
    r_left smallint NOT NULL, r_right smallint NOT NULL,
    l_top smallint NOT NULL, l_bottom smallint NOT NULL,
    l_left smallint NOT NULL, l_right smallint NOT NULL,
    /* the 0x8000 leaf bit, unpacked into an honest column */
    r_is_leaf bit NOT NULL, r_child int NOT NULL,
    l_is_leaf bit NOT NULL, l_child int NOT NULL
);

CREATE TABLE dbo.thing (
    id     int NOT NULL PRIMARY KEY,
    x      smallint NOT NULL,
    y      smallint NOT NULL,
    angle  smallint NOT NULL,
    type   smallint NOT NULL,      -- 1 = player 1 start
    flags  smallint NOT NULL
);
CREATE INDEX ix_thing_type ON dbo.thing(type);

/* Doom recomputes this at load time; materialise it instead. */
CREATE TABLE dbo.seg_sector (
    seg_id        int NOT NULL PRIMARY KEY REFERENCES dbo.seg(id),
    front_sector  int NULL REFERENCES dbo.sector(id),
    back_sector   int NULL REFERENCES dbo.sector(id)   -- NULL => solid
);

/* Doom's lighting model is a lookup table, which is to say a join. */
CREATE TABLE dbo.playpal (
    pal tinyint NOT NULL, idx tinyint NOT NULL,
    r tinyint NOT NULL, g tinyint NOT NULL, b tinyint NOT NULL,
    PRIMARY KEY (pal, idx)
);

CREATE TABLE dbo.colormap (
    light_level tinyint NOT NULL,   -- 0 = brightest, 31 = black, 32 = invuln
    in_idx      tinyint NOT NULL,
    out_idx     tinyint NOT NULL,
    PRIMARY KEY (light_level, in_idx)
);
GO

/* ---------------------------------------------------------------------
   The floorplan. Open this in SSMS and hit the "Spatial results" tab.
   Set the label column to "layer" to colour walls, portals and things.
   --------------------------------------------------------------------- */
CREATE VIEW dbo.v_map_plan AS
SELECT  l.id,
        layer = CASE WHEN l.left_sidedef IS NULL THEN 'wall' ELSE 'portal' END,
        shape = geometry::STGeomFromText(
            'LINESTRING(' + CONVERT(varchar(12), a.x) + ' ' + CONVERT(varchar(12), a.y)
            + ',' + CONVERT(varchar(12), b.x) + ' ' + CONVERT(varchar(12), b.y) + ')', 0)
FROM dbo.linedef l
JOIN dbo.vertex a ON a.id = l.v1
JOIN dbo.vertex b ON b.id = l.v2
UNION ALL
SELECT  t.id + 100000,
        layer = CASE t.type WHEN 1 THEN 'player start' ELSE 'thing' END,
        shape = geometry::STGeomFromText(
            'POINT(' + CONVERT(varchar(12), t.x) + ' ' + CONVERT(varchar(12), t.y) + ')', 0)
            .STBuffer(16)
FROM dbo.thing t;
GO

/* Which sector is each subsector in? Front sector of its first seg. */
CREATE VIEW dbo.v_subsector AS
SELECT ss.id, ss.first_seg, ss.last_seg, ss.seg_count, ss2.front_sector AS sector_id
FROM dbo.subsector ss
JOIN dbo.seg_sector ss2 ON ss2.seg_id = ss.first_seg;
GO

/* ---------------------------------------------------------------------
   BSP traversal as a recursive CTE. Returns every subsector in strict
   front-to-back order from the viewpoint (@px, @py) -- the exact order
   Doom's R_RenderBSPNode visits them, minus the recursion.

   The sort key is a path string: '0' at each node for the near child,
   '1' for the far one. Lexical order on that path IS painter's order.

       SELECT TOP 20 * FROM dbo.bsp_order(1056, -3616) ORDER BY visit;
   --------------------------------------------------------------------- */
CREATE FUNCTION dbo.bsp_order (@px float, @py float)
RETURNS TABLE
AS RETURN
(
    WITH walk AS (
        /* anchor: the root node is always the last one in the lump */
        SELECT  is_leaf = CONVERT(bit, 0),
                idx     = (SELECT MAX(id) FROM dbo.node),
                path    = CONVERT(varchar(64), ''),
                depth   = 0
        UNION ALL
        /* Sign of the cross product of the partition vector against the
           viewpoint says which side we're on; that side is the near child. */
        SELECT  is_leaf = CASE WHEN cs.ord = 0
                    THEN CASE WHEN (@px - n.part_x) * n.part_dy
                                 - (@py - n.part_y) * n.part_dx > 0
                              THEN n.r_is_leaf ELSE n.l_is_leaf END
                    ELSE CASE WHEN (@px - n.part_x) * n.part_dy
                                 - (@py - n.part_y) * n.part_dx > 0
                              THEN n.l_is_leaf ELSE n.r_is_leaf END END,
                idx     = CASE WHEN cs.ord = 0
                    THEN CASE WHEN (@px - n.part_x) * n.part_dy
                                 - (@py - n.part_y) * n.part_dx > 0
                              THEN n.r_child ELSE n.l_child END
                    ELSE CASE WHEN (@px - n.part_x) * n.part_dy
                                 - (@py - n.part_y) * n.part_dx > 0
                              THEN n.l_child ELSE n.r_child END END,
                path    = CONVERT(varchar(64), w.path + CONVERT(char(1), cs.ord)),
                depth   = w.depth + 1
        FROM walk w
        JOIN dbo.node n       ON n.id = w.idx AND w.is_leaf = 0
        JOIN dbo.child_slot cs ON 1 = 1
        WHERE w.depth < 48
    )
    SELECT  visit        = ROW_NUMBER() OVER (ORDER BY w.path),
            subsector_id = w.idx,
            depth        = w.depth,
            path         = w.path
    FROM walk w
    WHERE w.is_leaf = 1
);
GO

/* ------------------------------------------------------------------ */
CREATE PROCEDURE dbo.wad_validate AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @bad int;

    SELECT @bad = COUNT(*) FROM dbo.subsector ss
    WHERE ss.last_seg >= (SELECT COUNT(*) FROM dbo.seg) OR ss.first_seg < 0;
    IF @bad > 0 PRINT CONCAT('FAIL: ', @bad, ' subsectors point outside SEGS');

    SELECT @bad = COUNT(*) FROM dbo.node n
    WHERE (n.r_is_leaf = 1 AND n.r_child NOT IN (SELECT id FROM dbo.subsector))
       OR (n.l_is_leaf = 1 AND n.l_child NOT IN (SELECT id FROM dbo.subsector))
       OR (n.r_is_leaf = 0 AND n.r_child NOT IN (SELECT id FROM dbo.node))
       OR (n.l_is_leaf = 0 AND n.l_child NOT IN (SELECT id FROM dbo.node));
    IF @bad > 0 PRINT CONCAT('FAIL: ', @bad, ' nodes have dangling children');

    SELECT @bad = COUNT(*) FROM dbo.sector s
    WHERE NOT EXISTS (SELECT 1 FROM dbo.sidedef sd WHERE sd.sector_id = s.id);
    IF @bad > 0 PRINT CONCAT('warn: ', @bad, ' sectors have no sidedefs');

    /* every subsector must be reachable from the root exactly once */
    DECLARE @px float, @py float;
    SELECT TOP 1 @px = x, @py = y FROM dbo.thing WHERE type = 1;
    DECLARE @reached int = (SELECT COUNT(*) FROM dbo.bsp_order(@px, @py));
    DECLARE @total   int = (SELECT COUNT(*) FROM dbo.subsector);
    IF @reached <> @total
        PRINT CONCAT('FAIL: BSP walk reached ', @reached, ' of ', @total, ' subsectors');
    ELSE
        PRINT CONCAT('ok: BSP walk visits all ', @total, ' subsectors front-to-back');

    SELECT   [table] = 'vertex',    rows = COUNT(*) FROM dbo.vertex
    UNION ALL SELECT 'linedef',   COUNT(*) FROM dbo.linedef
    UNION ALL SELECT 'sidedef',   COUNT(*) FROM dbo.sidedef
    UNION ALL SELECT 'sector',    COUNT(*) FROM dbo.sector
    UNION ALL SELECT 'seg',       COUNT(*) FROM dbo.seg
    UNION ALL SELECT 'subsector', COUNT(*) FROM dbo.subsector
    UNION ALL SELECT 'node',      COUNT(*) FROM dbo.node
    UNION ALL SELECT 'thing',     COUNT(*) FROM dbo.thing
    UNION ALL SELECT 'playpal',   COUNT(*) FROM dbo.playpal
    UNION ALL SELECT 'colormap',  COUNT(*) FROM dbo.colormap;
END
GO
