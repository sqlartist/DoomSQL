# Running Doom in SQL Server

Fourteen steps, in this order. Each owns a disjoint set of objects, so any one of
them can be re-run on its own afterwards without disturbing the others.

| # | File | Creates | Re-runnable alone? |
|---|------|---------|--------------------|
| 1 | `E1M1_freedoom.sql` | schema + E1M1 geometry + 158 textures | yes, but it reloads all data (~10s) |
| 2 | `doom_render.sql` | `render_frame`, `sector_at`, `framebuffer` | yes |
| 3 | `doom_present.sql` | `frame_bmp`, `le4`, `screen_pixel`, `render_and_time` | yes |
| 4 | `doom_game.sql` | `player`, `input_state`, `line_collide`, `p_tick`, `game_loop` | yes |
| 5 | `doom_sprites.sql` | sprite tables + `render_sprites` | yes |
| 6 | `E1M1_sprites.sql` | 405 sprite frames, 16,688 columns | yes |
| 6b | `doom_sprites_fast.sql` | replaces `render_sprites`, adds `thing_sector` | yes, then `EXEC dbo.build_thing_sector` |
| 7 | `doom_client.sql` | `p_frame`, `p_input_set` | yes |
| 8 | `doom_doors.sql` | `door`, `p_use`, `p_door_tick`; **takes over** `build_collision`, `move_blocked`, `p_frame` | yes, then `EXEC dbo.build_collision` |
| 9 | `doom_sky.sql` | `render_sky`; final `p_frame` (all later stages are OBJECT_ID-guarded, so nothing redefines it again) | yes |
| 10 | `E1M1_sprites.sql` | **reload it**: now 444 frames, including the weapon HUD sprites | yes |
| 11 | `doom_weapons.sql` | inventory, pickups, firing, `render_psprite` | yes, then `EXEC dbo.setup_player` |
| 12 | `doom_statusbar.sql` | `hud_patch`, `hud_column`, `render_hud` | yes |
| 13 | `hud.sql` | 37 status bar patches (map-independent) | yes |

`doom_schema.sql` is NOT in the list: `E1M1_freedoom.sql` already embeds it.
Running it separately would drop the map data.

```
sqlcmd -S . -d doom -i E1M1_freedoom.sql
sqlcmd -S . -d doom -i doom_render.sql
sqlcmd -S . -d doom -i doom_present.sql
sqlcmd -S . -d doom -i doom_game.sql
sqlcmd -S . -d doom -i doom_sprites.sql
sqlcmd -S . -d doom -i E1M1_sprites.sql
sqlcmd -S . -d doom -i doom_sprites_fast.sql
sqlcmd -S . -d doom -i doom_client.sql
sqlcmd -S . -d doom -i doom_doors.sql
sqlcmd -S . -d doom -i doom_sky.sql
sqlcmd -S . -d doom -i E1M1_sprites.sql      # reload: weapon sprites added
sqlcmd -S . -d doom -i doom_weapons.sql
sqlcmd -S . -d doom -i doom_statusbar.sql
sqlcmd -S . -d doom -i hud.sql
```

`doom_doors.sql` must come after `doom_game.sql` and `doom_client.sql`: it
redefines `build_collision`, `move_blocked` and `p_frame`. Re-running either of
those later reverts the world to static. After loading it, run
`EXEC dbo.build_collision;` -- `line_collide` now stores sector ids rather than
cached opening heights, so doors can move without invalidating it.

After `doom_sprites_fast.sql`, run `EXEC dbo.build_thing_sector;` once -- it
precomputes which sector each thing stands in, which keeps a scalar UDF out of
the per-frame query.

`doom_sprites.sql` creates the tables and DELETEs their contents, so
`E1M1_sprites.sql` must follow it. `p_frame` calls `render_sprites` only if it
exists, so the game still runs without either.

## Play

```
.\doom_client.ps1 -Server . -Database doom
```

W/S move, A/D turn, Q/E strafe, Shift run, SPACE open doors, CTRL fire,
1-4 select weapon, R respawn, Esc quit.
`-Tics 12` advances more simulation per displayed frame; `-Scale 4` for a
bigger window.

## Check it before blaming it

```sql
EXEC dbo.doom_healthcheck;   -- doom_healthcheck.sql, optional but recommended
EXEC dbo.render_and_time;    -- run twice; the first pays a ~780ms compile
EXEC dbo.render_and_time;
```

Expect roughly: `render_ms` ~290, `present_ms` ~35, and `pixels_lit` close to
64,000 -- with sky and the status bar in, the frame is fully covered.

`pixels_lit = 0` means the texture tables are empty -- the rasteriser INNER
JOINs them, so it completes silently with no rows. Re-run `E1M1_freedoom.sql`.

## Other maps

```
python wad2sql.py FREEDOOM1.WAD --list
python wad2sql.py FREEDOOM1.WAD E1M3 -o E1M3.sql
python gen_sprites.py FREEDOOM1.WAD E1M3 -o E1M3_sprites.sql
```

Sprite data is per-map: only the sprites that map's things reference are
extracted, plus the player's weapons. The status bar graphics (`hud.sql`) are
map-independent and do not need regenerating.

Needs `wad2sql.py`, `wadtex.py`, `doom_schema.sql` and `doom_textures.sql` in
the same directory. Works on any vanilla-format IWAD or PWAD; extended
(ZDBSP-compressed) nodes are detected and rejected.

## Known gaps

- No monster AI: things are drawn, collide and can be shot, but nothing moves
  or fights back.
- Lifts, switches and walk-triggered lines: only manual (use) doors so far.
- The status bar face is static; Doom's reacts to damage and health.
- Locked doors refuse: there is no key inventory yet.
- Masked middle textures on two-sided lines (grates, vines) aren't drawn,
  though their alpha masks are stored.
- `game_loop` runs at ~12-15 tics/sec, not 35: `WAITFOR DELAY` rounds up to
  SQL Server's ~15.6ms timer resolution. The client's `p_frame` avoids this
  by batching tics per frame instead.

  Tested against FreeDoom (BSD-licensed) so the whole thing can be shared without redistributing commercial game data. It works with a retail DOOM.WAD too — same parser, same schema.
