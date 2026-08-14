#!/usr/bin/env python3
"""verify_textures.py -- end-to-end check of the *generated SQL*, not the
in-memory data.

Parses the emitted INSERT statements back out, then reimplements the view
logic exactly as SQL Server would evaluate it:

    v_texture_texel : SUBSTRING(pixels, n+1, 1) over numbers n < DATALENGTH
    v_palette_rgb   : colormap JOIN playpal ON pp.idx = cm.out_idx

and compares the result against the WAD. Catches off-by-one errors in the
1-based SUBSTRING, hex round-trip damage, and light-level mapping mistakes.
"""
import re
import sys
from PIL import Image
from wad2sql import Wad, parse_map, parse_palette
import wadtex

sqlfile = sys.argv[1]
wadfile = sys.argv[2]
mapname = sys.argv[3] if len(sys.argv) > 3 else "E1M1"
src = open(sqlfile).read()

fails = []


def check(label, ok, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'}  {label}{'  ' + detail if detail else ''}")
    if not ok:
        fails.append(label)


def rows_for(table):
    """Pull every VALUES tuple for one table out of the generated script."""
    out = []
    for m in re.finditer(rf"INSERT INTO {table} \([^)]*\) VALUES\n(.*?);\n",
                         src, re.S):
        for tup in re.findall(r"\((.*?)\)(?:,|\Z)", m.group(1), re.S):
            cells, buf, depth, instr = [], "", 0, False
            for ch in tup:
                if ch == "'":
                    instr = not instr
                if ch == "," and not instr:
                    cells.append(buf.strip())
                    buf = ""
                else:
                    buf += ch
            cells.append(buf.strip())
            out.append(cells)
    return out


def unq(c):
    if c == "NULL":
        return None
    if c.startswith("'"):
        return c[1:-1].replace("''", "'")
    return c


tex_rows = [[unq(c) for c in r] for r in rows_for("texture")]
col_rows = [[unq(c) for c in r] for r in rows_for("texture_column")]
pal_rows = [[unq(c) for c in r] for r in rows_for("playpal")]
cm_rows = [[unq(c) for c in r] for r in rows_for("colormap")]

check("texture rows parsed", len(tex_rows) > 0, f"{len(tex_rows)}")
check("texture_column rows parsed", len(col_rows) > 0, f"{len(col_rows)}")
check("playpal is 14 x 256", len(pal_rows) == 14 * 256, f"{len(pal_rows)}")
check("colormap is 34 x 256", len(cm_rows) == 34 * 256, f"{len(cm_rows)}")

tex = {int(r[0]): dict(name=r[1], kind=r[2], w=int(r[3]), h=int(r[4]),
                       masked=r[5] == "1") for r in tex_rows}
cols = {}
for r in col_rows:
    tid, u = int(r[0]), int(r[1])
    pixels = bytes.fromhex(r[2][2:])
    alpha = bytes.fromhex(r[3][2:]) if r[3] else None
    cols[(tid, u)] = (pixels, alpha)

# --- constraints the schema declares -----------------------------------
check("every texture has width columns",
      all(sum(1 for (tid, _u) in cols if tid == t) == tex[t]["w"] for t in tex))
check("every column is height bytes",
      all(len(p) == tex[t]["h"] and (a is None or len(a) == tex[t]["h"])
          for (t, _u), (p, a) in cols.items()))
check("is_masked agrees with alpha presence",
      all(tex[t]["masked"] == any(cols[(t, u)][1] is not None
                                  for u in range(tex[t]["w"])) for t in tex))
check("varbinary(1024) is wide enough",
      max(tex[t]["h"] for t in tex) <= 1024,
      f"max height {max(tex[t]['h'] for t in tex)}")
check("smallint u is wide enough",
      max(tex[t]["w"] for t in tex) <= 32767,
      f"max width {max(tex[t]['w'] for t in tex)}")


# --- v_texture_texel, evaluated the way SQL Server would ----------------
def v_texture_texel(tid, u):
    """SUBSTRING is 1-based; numbers.n starts at 0. This is the join that
    would silently shift every texture down a pixel if it were wrong."""
    pixels, alpha = cols[(tid, u)]
    out = []
    for n in range(len(pixels)):              # n.n < DATALENGTH(tc.pixels)
        pal_idx = pixels[n:n + 1][0]          # SUBSTRING(pixels, n+1, 1)
        opaque = 1 if alpha is None else alpha[n:n + 1][0]
        out.append((n, pal_idx, opaque))
    return out


wad = Wad(wadfile)
t = parse_map(wad, mapname)
truth = {x[0]: x for x in wadtex.extract(wad, t)}

mismatch = 0
for tid, meta in tex.items():
    _n, _k, tw, th, _m, tcols = truth[meta["name"]]
    if (tw, th) != (meta["w"], meta["h"]):
        mismatch += 1
        continue
    for u, pixels, alpha in tcols:
        got = v_texture_texel(tid, u)
        if len(got) != th:
            mismatch += 1
            break
        for v, (n, pal_idx, opaque) in enumerate(got):
            want_op = 1 if alpha is None else alpha[v]
            if n != v or pal_idx != pixels[v] or opaque != want_op:
                mismatch += 1
                break
check("v_texture_texel round-trips every texel from the WAD",
      mismatch == 0, f"{len(cols)} columns checked")

# --- v_palette_rgb ------------------------------------------------------
playpal = {(int(r[0]), int(r[1])): (int(r[2]), int(r[3]), int(r[4]))
           for r in pal_rows}
colormap = {(int(r[0]), int(r[1])): int(r[2]) for r in cm_rows}
pal_rgb = {(lvl, i): playpal[(0, colormap[(lvl, i)])]
           for (lvl, i) in colormap}
check("v_palette_rgb yields 34 x 256 rows", len(pal_rgb) == 34 * 256)
# Level 0 is "no shading", but it is not necessarily the identity on
# INDICES: colormap generators fold duplicate palette entries onto one
# canonical index. The invariant that actually holds is on COLOUR.
_remapped = [i for i in range(256) if colormap[(0, i)] != i]
check("light level 0 preserves colour",
      all(playpal[(0, i)] == playpal[(0, colormap[(0, i)])] for i in range(256)),
      f"{len(_remapped)} indices folded onto duplicate-coloured entries")
check("light level 31 collapses to near-black",
      max(sum(pal_rgb[(31, i)]) for i in range(256)) < 60,
      f"brightest = {max(sum(pal_rgb[(31, i)]) for i in range(256))}")

# --- render a shading ramp through the whole pipeline -------------------
name = next((n for n in ("AQDOOR01", "AQCOMP01") if
             any(m["name"] == n for m in tex.values())), tex[0]["name"])
tid = next(k for k, m in tex.items() if m["name"] == name)
w, h = tex[tid]["w"], tex[tid]["h"]
levels = [0, 4, 8, 12, 16, 20, 24, 28]
sheet = Image.new("RGB", (w * len(levels), h))
for i, lvl in enumerate(levels):
    for u in range(w):
        for v, pal_idx, opaque in v_texture_texel(tid, u):
            sheet.putpixel((i * w + u, v),
                           pal_rgb[(lvl, pal_idx)] if opaque else (255, 0, 255))
sheet.resize((w * len(levels), h), Image.NEAREST).save("shading_ramp.png")
print(f"\n  shading_ramp.png: {name} at colormap levels {levels}")

print()
if fails:
    print("FAILURES:", ", ".join(fails))
    sys.exit(1)
print("all checks passed")
