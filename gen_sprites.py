#!/usr/bin/env python3
"""gen_sprites.py -- emit the sprite data for a map as T-SQL.

    python gen_sprites.py FREEDOOM1.WAD E1M1 -o E1M1_sprites.sql

Run doom_sprites.sql first (it creates the tables), then this.
"""
import argparse, os, sys
from wad2sql import Wad, parse_map, inserts, hex_inserts, COLUMNS, emit_sprites

ap = argparse.ArgumentParser()
ap.add_argument("wad"); ap.add_argument("map")
ap.add_argument("-o", "--out", default=None)
a = ap.parse_args()

wad = Wad(a.wad)
t = parse_map(wad, a.map)
warn = []
mobj_rows, frame_rows, col_rows = emit_sprites(wad, t, warn)

print(f"  mobj_type     {len(mobj_rows):>6}", file=sys.stderr)
print(f"  sprite_frame  {len(frame_rows):>6}", file=sys.stderr)
print(f"  sprite_column {len(col_rows):>6}", file=sys.stderr)
for w in warn:
    print(f"  warn: {w}", file=sys.stderr)

out = a.out or f"{a.map}_sprites.sql"
parts = [f"/* sprite data for {a.map} from {os.path.basename(a.wad)} */\n",
         "SET NOCOUNT ON;\n",
         "DELETE FROM dbo.sprite_column;",
         "DELETE FROM dbo.sprite_frame;",
         "DELETE FROM dbo.mobj_type;\n",
         inserts("dbo.mobj_type", COLUMNS["mobj_type"], mobj_rows),
         inserts("dbo.sprite_frame", COLUMNS["sprite_frame"], frame_rows),
         hex_inserts("dbo.sprite_column", COLUMNS["sprite_column"], col_rows),
         "\nSELECT frames = (SELECT COUNT(*) FROM dbo.sprite_frame),",
         "       columns_ = (SELECT COUNT(*) FROM dbo.sprite_column),",
         "       types = (SELECT COUNT(*) FROM dbo.mobj_type);\n"]
with open(out, "w") as f:
    f.write("\n".join(parts))
print(f"wrote {out} ({os.path.getsize(out)/1024:.0f} KB)", file=sys.stderr)
