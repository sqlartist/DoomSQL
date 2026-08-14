/* =====================================================================
   doom_healthcheck.sql -- is the database in a state that can render?

   Run this before blaming the rasteriser. Every empty table below produces
   a black frame or an error rather than anything useful, and the texture
   tables in particular can be emptied by re-running doom_textures.sql.
   ===================================================================== */

IF OBJECT_ID('dbo.doom_healthcheck') IS NOT NULL DROP PROCEDURE dbo.doom_healthcheck;
GO

CREATE PROCEDURE dbo.doom_healthcheck AS
BEGIN
    SET NOCOUNT ON;

    WITH c AS (
        SELECT t = 'vertex',         n = (SELECT COUNT(*) FROM dbo.vertex)
        UNION ALL SELECT 'linedef',      (SELECT COUNT(*) FROM dbo.linedef)
        UNION ALL SELECT 'sidedef',      (SELECT COUNT(*) FROM dbo.sidedef)
        UNION ALL SELECT 'sector',       (SELECT COUNT(*) FROM dbo.sector)
        UNION ALL SELECT 'seg',          (SELECT COUNT(*) FROM dbo.seg)
        UNION ALL SELECT 'seg_sector',   (SELECT COUNT(*) FROM dbo.seg_sector)
        UNION ALL SELECT 'subsector',    (SELECT COUNT(*) FROM dbo.subsector)
        UNION ALL SELECT 'node',         (SELECT COUNT(*) FROM dbo.node)
        UNION ALL SELECT 'thing',        (SELECT COUNT(*) FROM dbo.thing)
        UNION ALL SELECT 'playpal',      (SELECT COUNT(*) FROM dbo.playpal)
        UNION ALL SELECT 'colormap',     (SELECT COUNT(*) FROM dbo.colormap)
        UNION ALL SELECT 'texture',      (SELECT COUNT(*) FROM dbo.texture)
        UNION ALL SELECT 'texture_column', (SELECT COUNT(*) FROM dbo.texture_column)
        UNION ALL SELECT 'numbers',      (SELECT COUNT(*) FROM dbo.numbers)
        UNION ALL SELECT 'screen_pixel', (SELECT COUNT(*) FROM dbo.screen_pixel)
    )
    SELECT c.t AS [table], c.n AS rows_,
           status = CASE WHEN c.n = 0 THEN 'EMPTY -- renders black'
                         ELSE 'ok' END
    FROM c;

    /* the specific failure that costs the most time to diagnose */
    IF (SELECT COUNT(*) FROM dbo.texture) = 0
        PRINT 'texture is empty: the rasteriser INNER JOINs it, so every pixel '
            + 'is discarded and render_frame completes silently with 0 rows. '
            + 'Re-run the generated <MAP>.sql.';

    /* a player start is required by render_and_time */
    IF NOT EXISTS (SELECT 1 FROM dbo.thing WHERE type = 1)
        PRINT 'no player 1 start (thing type 1) in this map.';

    /* names the map references that no texture row satisfies */
    SELECT unresolved_texture = v.nm, referenced_by = COUNT(*)
    FROM dbo.sidedef sd
    CROSS APPLY (VALUES (sd.upper_tex), (sd.middle_tex), (sd.lower_tex)) v(nm)
    WHERE v.nm <> '-'
      AND NOT EXISTS (SELECT 1 FROM dbo.texture t WHERE t.name = v.nm)
    GROUP BY v.nm
    ORDER BY COUNT(*) DESC;
END
GO
