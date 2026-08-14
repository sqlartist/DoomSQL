#!/usr/bin/env python3
"""
gen_hud.py -- extract the status bar graphics as T-SQL.

    python gen_hud.py FREEDOOM1.WAD -o hud.sql

These are ordinary Doom picture-format patches, same as wall patches and
sprites, but they sit loose in the WAD rather than between markers -- nothing
references them, so they have to be named. They are also map-independent, so
this runs once rather than per level.
"""
import argparse
import os
import sys

from wad2sql import Wad, inserts, hex_inserts, q
from wadsprite import decode_patch_full

WANTED = (
    ['STBAR', 'STARMS', 'STTPRCNT', 'STTMINUS', 'STFST01']
    + [f'STTNUM{i}' for i in range(10)]        # big red digits
    + [f'STYSNUM{i}' for i in range(10)]       # small yellow digits
    + [f'STGNUM{i}' for i in range(2, 8)]      # grey arms numbers
    + [f'STKEYS{i}' for i in range(6)]
)

COLUMNS = {
    'hud_patch':  ['id', 'name', 'width', 'height', 'left_off', 'top_off'],
    'hud_column': ['patch_id', 'u', 'pixels', 'alpha'],
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('wad')
    ap.add_argument('-o', '--out', default='hud.sql')
    a = ap.parse_args()

    wad = Wad(a.wad)
    patch_rows, col_rows, missing = [], [], []

    for pid, name in enumerate(WANTED):
        i = wad.find(name)
        if i is None:
            missing.append(name)
            continue
        w, h, left, top, cols = decode_patch_full(wad.lump(i))
        patch_rows.append((pid, name, w, h, left, top))
        for u, col in enumerate(cols):
            pixels = bytes(0 if c is None else c for c in col)
            alpha = (bytes(0 if c is None else 1 for c in col)
                     if any(c is None for c in col) else None)
            col_rows.append((pid, u, '0x' + pixels.hex(),
                             '0x' + alpha.hex() if alpha else None))

    print(f'  hud_patch  {len(patch_rows):>6}', file=sys.stderr)
    print(f'  hud_column {len(col_rows):>6}', file=sys.stderr)
    for m in missing:
        print(f'  warn: lump {m} not in this WAD', file=sys.stderr)

    parts = [
        f'/* status bar graphics from {os.path.basename(a.wad)} */\n',
        'SET NOCOUNT ON;\n',
        'DELETE FROM dbo.hud_column;',
        'DELETE FROM dbo.hud_patch;\n',
        inserts('dbo.hud_patch', COLUMNS['hud_patch'], patch_rows),
        hex_inserts('dbo.hud_column', COLUMNS['hud_column'], col_rows),
        '\nSELECT patches = (SELECT COUNT(*) FROM dbo.hud_patch),'
        ' columns_ = (SELECT COUNT(*) FROM dbo.hud_column);\n',
    ]
    with open(a.out, 'w') as f:
        f.write('\n'.join(parts))
    print(f'wrote {a.out} ({os.path.getsize(a.out)/1024:.0f} KB)', file=sys.stderr)


if __name__ == '__main__':
    main()
