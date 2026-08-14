/* =====================================================================
   doom_textures.sql -- stage 2. Run after doom_schema.sql and the map load.

   *** THIS SCRIPT IS DESTRUCTIVE AND IS ALREADY EMBEDDED IN THE GENERATED
   *** <MAP>.sql. You almost never need to run it on its own. Running it
   *** after a load DROPs texture and texture_column and leaves them empty,
   *** which makes render_frame produce a black frame with no error at all
   *** -- the texture join in the rasteriser is an INNER JOIN.
   *** If you have just done that: re-run the generated <MAP>.sql.

   STORAGE DECISION worth understanding before you change it:

   One row per texel is the obvious relational model and it is the wrong
   one. E1M1 alone references 1.4 million texels; a full IWAD is tens of
   millions. Instead each texture COLUMN is one row holding a varbinary of
   palette indices -- which happens to be exactly how Doom stores them,
   because Doom's renderer is column-based.

   That keeps the join where it belongs. The rasteriser joins once per
   (surface, screen column) -- a few hundred seeks per frame -- and pulls
   individual texels with SUBSTRING inside the row it already has:

       JOIN texture_column tc
         ON tc.texture_id = w.tex_id AND tc.u = w.u % w.width
       ... pal_idx = CONVERT(tinyint, SUBSTRING(tc.pixels, w.v % w.height + 1, 1))

   v_texture_texel below explodes columns back into one row per texel. It's
   for inspection and sanity checks, not the hot path -- it's a non-equijoin
   against a numbers table and will nested-loop itself into the ground if you
   put it in a renderer.
   ===================================================================== */

IF OBJECT_ID('dbo.tex_sample')        IS NOT NULL DROP FUNCTION dbo.tex_sample;
IF OBJECT_ID('dbo.tex_validate')      IS NOT NULL DROP PROCEDURE dbo.tex_validate;
IF OBJECT_ID('dbo.v_texture_texel')   IS NOT NULL DROP VIEW dbo.v_texture_texel;
IF OBJECT_ID('dbo.v_palette_rgb')     IS NOT NULL DROP VIEW dbo.v_palette_rgb;
IF OBJECT_ID('dbo.v_sidedef_texture') IS NOT NULL DROP VIEW dbo.v_sidedef_texture;
IF OBJECT_ID('dbo.v_sector_flat')     IS NOT NULL DROP VIEW dbo.v_sector_flat;
GO
IF OBJECT_ID('dbo.texture_column') IS NOT NULL DROP TABLE dbo.texture_column;
IF OBJECT_ID('dbo.texture')        IS NOT NULL DROP TABLE dbo.texture;
IF OBJECT_ID('dbo.numbers')        IS NOT NULL DROP TABLE dbo.numbers;
GO

CREATE TABLE dbo.numbers (n int NOT NULL PRIMARY KEY);
INSERT INTO dbo.numbers (n)
SELECT TOP (4096) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
FROM sys.all_objects a CROSS JOIN sys.all_objects b;
GO

CREATE TABLE dbo.texture (
    id         int NOT NULL PRIMARY KEY,
    name       varchar(8) NOT NULL UNIQUE,
    kind       varchar(4) NOT NULL,     -- 'wall' (composite) or 'flat' (raw 64x64)
    width      smallint NOT NULL,
    height     smallint NOT NULL,
    is_masked  bit NOT NULL             -- has transparent texels: grates, vines
);

CREATE TABLE dbo.texture_column (
    texture_id  int NOT NULL REFERENCES dbo.texture(id),
    u           smallint NOT NULL,
    pixels      varbinary(1024) NOT NULL,   -- height bytes of palette indices
    alpha       varbinary(1024) NULL,       -- NULL when the column is solid
    CONSTRAINT pk_texture_column PRIMARY KEY (texture_id, u)
);
GO

/* ---------------------------------------------------------------------
   THE lighting join. Doom's lighting model is a lookup table: COLORMAP
   maps (light level, palette index) -> palette index, and PLAYPAL maps
   palette index -> RGB. Compose them once and light becomes a two-column
   equijoin. 34 levels x 256 entries = 8,704 rows, level 0 brightest,
   31 fully dark, 32 the invulnerability inverse.
   --------------------------------------------------------------------- */
CREATE VIEW dbo.v_palette_rgb AS
SELECT  cm.light_level,
        cm.in_idx,
        pp.r, pp.g, pp.b
FROM dbo.colormap cm
JOIN dbo.playpal pp ON pp.pal = 0 AND pp.idx = cm.out_idx;
GO

/* Inspection only -- see the header note. */
CREATE VIEW dbo.v_texture_texel AS
SELECT  tc.texture_id,
        tc.u,
        v       = CONVERT(smallint, n.n),
        pal_idx = CONVERT(tinyint, SUBSTRING(tc.pixels, n.n + 1, 1)),
        opaque  = CONVERT(bit, CASE WHEN tc.alpha IS NULL THEN 1
                       ELSE CONVERT(tinyint, SUBSTRING(tc.alpha, n.n + 1, 1)) END)
FROM dbo.texture_column tc
JOIN dbo.numbers n ON n.n < DATALENGTH(tc.pixels);
GO

/* Resolve the map's texture names to ids. Sidedefs carry three slots and
   '-' means "nothing here", which is why these are separate rows. */
CREATE VIEW dbo.v_sidedef_texture AS
SELECT sd.id AS sidedef_id, part = 'upper',  t.id AS texture_id
FROM dbo.sidedef sd JOIN dbo.texture t ON t.name = sd.upper_tex AND t.kind = 'wall'
UNION ALL
SELECT sd.id, 'middle', t.id
FROM dbo.sidedef sd JOIN dbo.texture t ON t.name = sd.middle_tex AND t.kind = 'wall'
UNION ALL
SELECT sd.id, 'lower', t.id
FROM dbo.sidedef sd JOIN dbo.texture t ON t.name = sd.lower_tex AND t.kind = 'wall';
GO

CREATE VIEW dbo.v_sector_flat AS
SELECT s.id AS sector_id, surface = 'floor', t.id AS texture_id,
       light_level = CONVERT(tinyint, 31 - (s.light / 8))
FROM dbo.sector s JOIN dbo.texture t ON t.name = s.floor_tex AND t.kind = 'flat'
UNION ALL
SELECT s.id, 'ceiling', t.id, CONVERT(tinyint, 31 - (s.light / 8))
FROM dbo.sector s JOIN dbo.texture t ON t.name = s.ceil_tex AND t.kind = 'flat';
GO

/* ---------------------------------------------------------------------
   Sample a whole texture at a given light level. Texel -> shaded RGB is
   two joins, which is the entire back end of Doom's pixel pipeline.

       SELECT * FROM dbo.tex_sample(
           (SELECT id FROM dbo.texture WHERE name = 'AQDOOR01'), 12);
   --------------------------------------------------------------------- */
CREATE FUNCTION dbo.tex_sample (@texture_id int, @light tinyint)
RETURNS TABLE
AS RETURN
(
    SELECT  t.u, t.v, t.opaque, p.r, p.g, p.b
    FROM dbo.v_texture_texel t
    JOIN dbo.v_palette_rgb p
      ON p.light_level = @light AND p.in_idx = t.pal_idx
    WHERE t.texture_id = @texture_id
);
GO

CREATE PROCEDURE dbo.tex_validate AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @bad int;

    SELECT @bad = COUNT(*) FROM dbo.texture t
    WHERE (SELECT COUNT(*) FROM dbo.texture_column c WHERE c.texture_id = t.id) <> t.width;
    IF @bad > 0 PRINT CONCAT('FAIL: ', @bad, ' textures have the wrong column count');

    SELECT @bad = COUNT(*) FROM dbo.texture t
    JOIN dbo.texture_column c ON c.texture_id = t.id
    WHERE DATALENGTH(c.pixels) <> t.height
       OR (c.alpha IS NOT NULL AND DATALENGTH(c.alpha) <> t.height);
    IF @bad > 0 PRINT CONCAT('FAIL: ', @bad, ' columns are the wrong height');

    SELECT @bad = COUNT(*) FROM dbo.texture t
    WHERE t.is_masked = 0
      AND EXISTS (SELECT 1 FROM dbo.texture_column c
                  WHERE c.texture_id = t.id AND c.alpha IS NOT NULL);
    IF @bad > 0 PRINT CONCAT('FAIL: ', @bad, ' textures claim solid but carry alpha');

    /* every wall texture the map names must have arrived */
    SELECT @bad = COUNT(*) FROM dbo.sidedef sd
    CROSS APPLY (VALUES (sd.upper_tex), (sd.middle_tex), (sd.lower_tex)) v(nm)
    WHERE v.nm <> '-' AND NOT EXISTS
        (SELECT 1 FROM dbo.texture t WHERE t.name = v.nm AND t.kind = 'wall');
    IF @bad > 0 PRINT CONCAT('FAIL: ', @bad, ' sidedef slots reference a missing texture');

    SELECT @bad = COUNT(*) FROM dbo.sector s
    CROSS APPLY (VALUES (s.floor_tex), (s.ceil_tex)) v(nm)
    WHERE NOT EXISTS (SELECT 1 FROM dbo.texture t WHERE t.name = v.nm AND t.kind = 'flat');
    IF @bad > 0 PRINT CONCAT('FAIL: ', @bad, ' sector surfaces reference a missing flat');

    IF (SELECT COUNT(*) FROM dbo.v_palette_rgb) <> 34 * 256
        PRINT 'FAIL: v_palette_rgb is not 34 x 256';

    SELECT kind, textures = COUNT(*), columns_ = SUM(width),
           texels = SUM(CONVERT(bigint, width) * height),
           masked = SUM(CONVERT(int, is_masked))
    FROM dbo.texture GROUP BY kind;
END
GO

/* Loud rather than silent: say what state this left the tables in. */
DECLARE @tex int = (SELECT COUNT(*) FROM dbo.texture);
IF @tex = 0
    PRINT 'WARNING: texture is empty. If you ran this standalone after loading '
        + 'a map, the texture data has just been dropped -- re-run the '
        + 'generated <MAP>.sql to restore it.';
ELSE
    PRINT CONCAT('texture rows: ', @tex);
GO
