/* =====================================================================
   doom_client.sql -- stage 5. One round trip per displayed frame.

   Run after doom_game.sql.

   The client shouldn't chat: sending a tic, then a render, then a fetch is
   three round trips per frame. p_frame does all of it server-side and hands
   back a BMP, so the network cost is one call regardless of how many tics
   are simulated between frames.

   The simulation and the view are still decoupled. @tics is how many 35Hz
   tics to advance before drawing, so a ~3fps rasteriser and a 35Hz game can
   coexist: pass @tics = 12 and each displayed frame covers a third of a
   second of simulated time.
   ===================================================================== */

IF OBJECT_ID('dbo.p_frame') IS NOT NULL DROP PROCEDURE dbo.p_frame;
GO

CREATE PROCEDURE dbo.p_frame @tics int = 4
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @i int = 0;
    WHILE @i < @tics
    BEGIN
        EXEC dbo.p_tick;
        SET @i += 1;
    END

    DECLARE @px float, @py float, @ang float;
    SELECT @px = x, @py = y, @ang = angle FROM dbo.player WHERE id = 1;

    EXEC dbo.render_frame @px, @py, @ang;

    /* sprites paint over the walls, so they run after. Guarded so the client
       still works if doom_sprites.sql has not been loaded. */
    IF OBJECT_ID('dbo.render_sprites') IS NOT NULL
        EXEC dbo.render_sprites @px, @py, @ang;

    SELECT bmp = dbo.frame_bmp();
END
GO

/* Set several keys in one round trip. The client sends this on every frame
   rather than firing p_input per keystroke, so held keys stay in sync even
   if a key event is missed. */
IF OBJECT_ID('dbo.p_input_set') IS NOT NULL DROP PROCEDURE dbo.p_input_set;
GO

CREATE PROCEDURE dbo.p_input_set
    @forward bit = 0, @back bit = 0,
    @turnleft bit = 0, @turnright bit = 0,
    @strafeleft bit = 0, @straferight bit = 0,
    @run bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    /* UPDATE the ALIAS, not the table name. "UPDATE dbo.input_state ... FROM
       dbo.input_state s" exposes the same table under two names and SQL Server
       rejects it (Msg 1013) -- which threw on every timer tick and was why the
       window never received a frame. */
    UPDATE s
       SET down = v.d
      FROM dbo.input_state s
      JOIN (VALUES ('forward', @forward), ('back', @back),
                   ('turnleft', @turnleft), ('turnright', @turnright),
                   ('strafeleft', @strafeleft), ('straferight', @straferight),
                   ('run', @run)) v(k, d) ON v.k = s.k;
END
GO
