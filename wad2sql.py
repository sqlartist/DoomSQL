#!/usr/bin/env python3
"""
wad2sql.py -- turn a Doom WAD map into a SQL Server relational schema.

A WAD map is already a normalised database: integer foreign keys, fixed-width
records, no nulls. This just makes that explicit.

    python wad2sql.py DOOM.WAD E1M1 -o E1M1.sql
    python wad2sql.py DOOM.WAD --list
    python wad2sql.py DOOM.WAD E1M1 --csv out/     # BULK INSERT route

Works on any vanilla-format IWAD/PWAD (Doom, Doom II, FreeDoom, most PWADs).
Hexen-format and compressed (ZDBSP) node builds are detected and rejected.
"""

import argparse
import os
import struct
import sys

# ---------------------------------------------------------------- WAD container

MAP_LUMPS = ("THINGS", "LINEDEFS", "SIDEDEFS", "VERTEXES", "SEGS",
             "SSECTORS", "NODES", "SECTORS", "REJECT", "BLOCKMAP")

NONE16 = 0xFFFF          # Doom's "no such index" sentinel
SUBSECTOR_BIT = 0x8000   # set in a NODES child pointer => index is a subsector


class Wad:
    def __init__(self, path):
        with open(path, "rb") as f:
            self.data = f.read()
        magic, count, dir_ofs = struct.unpack_from("<4sii", self.data, 0)
        if magic not in (b"IWAD", b"PWAD"):
            raise ValueError(f"{path}: not a WAD (magic {magic!r})")
        self.kind = magic.decode()
        self.directory = []
        for i in range(count):
            pos, size, raw = struct.unpack_from("<ii8s", self.data, dir_ofs + i * 16)
            name = raw.split(b"\0")[0].decode("ascii", "replace").upper()
            self.directory.append((name, pos, size))

    def lump(self, index):
        _, pos, size = self.directory[index]
        return self.data[pos:pos + size]

    def find(self, name, start=0):
        name = name.upper()
        for i in range(start, len(self.directory)):
            if self.directory[i][0] == name:
                return i
        return None

    def maps(self):
        """Any lump immediately followed by THINGS is a map marker."""
        out = []
        for i in range(len(self.directory) - 1):
            if self.directory[i + 1][0] == "THINGS" and self.directory[i][2] == 0:
                out.append(self.directory[i][0])
        return out

    def map_lumps(self, map_name):
        i = self.find(map_name)
        if i is None:
            raise KeyError(f"map {map_name} not in WAD")
        found = {}
        for j in range(i + 1, min(i + 12, len(self.directory))):
            nm = self.directory[j][0]
            if nm in ("BEHAVIOR", "SCRIPTS"):
                raise ValueError(f"{map_name} is Hexen format; not supported")
            if nm not in MAP_LUMPS:
                break
            found[nm] = self.lump(j)
        missing = [n for n in MAP_LUMPS[:8] if n not in found]
        if missing:
            raise ValueError(f"{map_name} missing lumps: {missing}")
        if found["NODES"][:4] in (b"XNOD", b"ZNOD", b"XGLN", b"ZGLN"):
            raise ValueError(f"{map_name} uses extended/compressed nodes; "
                             "rebuild with a vanilla node builder")
        return found


def records(blob, fmt):
    size = struct.calcsize(fmt)
    for off in range(0, len(blob) - size + 1, size):
        yield struct.unpack_from(fmt, blob, off)


def tex(raw):
    """8-byte texture name -> str. '-' means 'no texture here'."""
    return raw.split(b"\0")[0].decode("ascii", "replace").upper()


# ---------------------------------------------------------------- map -> tables

def parse_map(wad, map_name):
    L = wad.map_lumps(map_name)
    t = {}

    t["vertex"] = [(i, x, y) for i, (x, y) in
                   enumerate(records(L["VERTEXES"], "<hh"))]

    t["sector"] = [(i, fh, ch, tex(ft), tex(ct), light, special, tag)
                   for i, (fh, ch, ft, ct, light, special, tag)
                   in enumerate(records(L["SECTORS"], "<hh8s8shhh"))]

    t["sidedef"] = [(i, xo, yo, tex(up), tex(lo), tex(mid), sec)
                    for i, (xo, yo, up, lo, mid, sec)
                    in enumerate(records(L["SIDEDEFS"], "<hh8s8s8sH"))]

    t["linedef"] = [(i, v1, v2, flags, special, tag,
                     None if r == NONE16 else r,
                     None if l == NONE16 else l)
                    for i, (v1, v2, flags, special, tag, r, l)
                    in enumerate(records(L["LINEDEFS"], "<HHhhhHH"))]

    t["seg"] = [(i, v1, v2, angle, ld, side, offset)
                for i, (v1, v2, angle, ld, side, offset)
                in enumerate(records(L["SEGS"], "<HHhHhh"))]

    t["subsector"] = [(i, first, first + n - 1, n)
                      for i, (n, first) in enumerate(records(L["SSECTORS"], "<HH"))]

    # NODES children encode leaf-vs-node in the top bit. Split that out into
    # proper columns so the recursive CTE doesn't need bit twiddling.
    nodes = []
    for i, r in enumerate(records(L["NODES"], "<hhhh" + "hhhh" * 2 + "HH")):
        x, y, dx, dy = r[0:4]
        rt, rb, rl, rr = r[4:8]
        lt, lb, ll, lr = r[8:12]
        cr, cl = r[12], r[13]
        nodes.append((i, x, y, dx, dy, rt, rb, rl, rr, lt, lb, ll, lr,
                      1 if cr & SUBSECTOR_BIT else 0, cr & 0x7FFF,
                      1 if cl & SUBSECTOR_BIT else 0, cl & 0x7FFF))
    t["node"] = nodes

    t["thing"] = [(i, x, y, angle, typ, flags)
                  for i, (x, y, angle, typ, flags)
                  in enumerate(records(L["THINGS"], "<hhhhh"))]

    # Derived: which sector does each seg belong to? (front sidedef's sector)
    # Doom recomputes this at load time; we materialise it.
    side_sector = {s[0]: s[6] for s in t["sidedef"]}
    line_sides = {l[0]: (l[6], l[7]) for l in t["linedef"]}
    seg_sector = []
    for (i, v1, v2, angle, ld, side, offset) in t["seg"]:
        front, back = line_sides.get(ld, (None, None))
        sd = back if side else front
        opp = front if side else back
        seg_sector.append((i,
                           side_sector.get(sd) if sd is not None else None,
                           side_sector.get(opp) if opp is not None else None))
    t["seg_sector"] = seg_sector
    return t


def parse_palette(wad):
    """PLAYPAL + COLORMAP. Doom's lighting model is a lookup table, i.e. a join."""
    out = {}
    i = wad.find("PLAYPAL")
    if i is not None:
        blob = wad.lump(i)
        rows = []
        for pal in range(len(blob) // 768):
            base = pal * 768
            for idx in range(256):
                r, g, b = blob[base + idx * 3: base + idx * 3 + 3]
                rows.append((pal, idx, r, g, b))
        out["playpal"] = rows
    i = wad.find("COLORMAP")
    if i is not None:
        blob = wad.lump(i)
        rows = []
        for lvl in range(len(blob) // 256):
            for idx in range(256):
                rows.append((lvl, idx, blob[lvl * 256 + idx]))
        out["colormap"] = rows
    return out


# ---------------------------------------------------------------- SQL emission

def q(v):
    if v is None:
        return "NULL"
    if isinstance(v, str):
        return "'" + v.replace("'", "''") + "'"
    return str(v)


def inserts(table, cols, rows, batch=500):
    if not rows:
        return ""
    out = []
    collist = ", ".join(cols)
    for i in range(0, len(rows), batch):
        chunk = rows[i:i + batch]
        vals = ",\n".join("(" + ", ".join(q(v) for v in r) + ")" for r in chunk)
        out.append(f"INSERT INTO {table} ({collist}) VALUES\n{vals};\n")
    return "\n".join(out)


COLUMNS = {
    "vertex":     ["id", "x", "y"],
    "sector":     ["id", "floor_h", "ceil_h", "floor_tex", "ceil_tex",
                   "light", "special", "tag"],
    "sidedef":    ["id", "x_off", "y_off", "upper_tex", "lower_tex",
                   "middle_tex", "sector_id"],
    "linedef":    ["id", "v1", "v2", "flags", "special", "tag",
                   "right_sidedef", "left_sidedef"],
    "seg":        ["id", "v1", "v2", "angle", "linedef_id", "side", "offset_u"],
    "subsector":  ["id", "first_seg", "last_seg", "seg_count"],
    "node":       ["id", "part_x", "part_y", "part_dx", "part_dy",
                   "r_top", "r_bottom", "r_left", "r_right",
                   "l_top", "l_bottom", "l_left", "l_right",
                   "r_is_leaf", "r_child", "l_is_leaf", "l_child"],
    "thing":      ["id", "x", "y", "angle", "type", "flags"],
    "seg_sector": ["seg_id", "front_sector", "back_sector"],
    "playpal":    ["pal", "idx", "r", "g", "b"],
    "colormap":   ["light_level", "in_idx", "out_idx"],
    "texture":        ["id", "name", "kind", "width", "height", "is_masked"],
    "texture_column": ["texture_id", "u", "pixels", "alpha"],
    "mobj_type":     ["doomednum", "sprite", "frame", "full_bright"],
    "sprite_frame":  ["id", "sprite", "frame", "rotation", "width", "height",
                      "left_off", "top_off", "flip", "lump"],
    "sprite_column": ["frame_id", "u", "pixels", "alpha"],
}


def emit_textures(wad, t, warn):
    """Texture rows as hex literals. Columns, not texels -- see doom_textures.sql."""
    import wadtex
    tex = wadtex.extract(wad, t, warn)
    tex_rows, col_rows = [], []
    for tid, (name, kind, w, h, masked, cols) in enumerate(tex):
        tex_rows.append((tid, name, kind, w, h, 1 if masked else 0))
        for u, pixels, alpha in cols:
            col_rows.append((tid, u,
                             "0x" + pixels.hex(),
                             "0x" + alpha.hex() if alpha is not None else None))
    return tex, tex_rows, col_rows


def hex_inserts(table, cols, rows, batch=200):
    """Like inserts(), but leaves 0x... literals unquoted."""
    out = []
    collist = ", ".join(cols)
    for i in range(0, len(rows), batch):
        vals = []
        for r in rows[i:i + batch]:
            cells = [v if isinstance(v, str) and v.startswith("0x") else q(v)
                     for v in r]
            vals.append("(" + ", ".join(cells) + ")")
        out.append(f"INSERT INTO {table} ({collist}) VALUES\n"
                   + ",\n".join(vals) + ";\n")
    return "\n".join(out)


def emit_sprites(wad, t, warn):
    """Sprite rows. Same picture format as textures, so the same column-major
    storage; the extra columns are frame, rotation and the hang offsets."""
    import wadsprite
    frames, unknown = wadsprite.extract(wad, t["thing"], warn)
    for u in unknown:
        warn.append(f"thing type {u} has no entry in wadsprite.MOBJ")

    frame_rows, col_rows = [], []
    for fid, (key, f) in enumerate(sorted(frames.items())):
        sprite, frame, rot = key
        frame_rows.append((fid, sprite, frame, rot, f["w"], f["h"],
                           f["left"], f["top"], 1 if f["flip"] else 0,
                           f["lump"]))
        for u, col in enumerate(f["cols"]):
            pixels = bytes(0 if c is None else c for c in col)
            alpha = (bytes(0 if c is None else 1 for c in col)
                     if any(c is None for c in col) else None)
            col_rows.append((fid, u, "0x" + pixels.hex(),
                             "0x" + alpha.hex() if alpha else None))

    used = {th[4] for th in t["thing"]}
    mobj_rows = [(n, v[0], v[1], v[2])
                 for n, v in sorted(wadsprite.MOBJ.items()) if n in used]
    return mobj_rows, frame_rows, col_rows


def emit_sql(t, pal, map_name, wad_name, schema_path, textures=None,
             tex_schema_path=None):
    with open(schema_path) as f:
        ddl = f.read()
    parts = [
        f"/* {map_name} from {wad_name}, generated by wad2sql.py */\n",
        ddl,
        "\nSET NOCOUNT ON;\n",
        f"DELETE FROM map_meta; INSERT INTO map_meta (map_name, source_wad) "
        f"VALUES ({q(map_name)}, {q(wad_name)});\n",
    ]
    order = ["vertex", "sector", "sidedef", "linedef", "seg", "subsector",
             "node", "thing", "seg_sector"]
    for name in order:
        parts.append(f"\n/* ---- {name}: {len(t[name])} rows ---- */")
        parts.append(inserts(name, COLUMNS[name], t[name]))
    for name in ("playpal", "colormap"):
        if name in pal:
            parts.append(f"\n/* ---- {name}: {len(pal[name])} rows ---- */")
            parts.append(inserts(name, COLUMNS[name], pal[name], batch=900))
    parts.append("\nEXEC dbo.wad_validate;\n")

    if textures:
        tex_rows, col_rows = textures
        with open(tex_schema_path) as f:
            parts.append("\nGO\n" + f.read())
        parts.append(f"\nSET NOCOUNT ON;\n")
        parts.append(f"\n/* ---- texture: {len(tex_rows)} rows ---- */")
        parts.append(inserts("texture", COLUMNS["texture"], tex_rows))
        parts.append(f"\n/* ---- texture_column: {len(col_rows)} rows ---- */")
        parts.append(hex_inserts("texture_column", COLUMNS["texture_column"],
                                 col_rows))
        parts.append("\nEXEC dbo.tex_validate;\n")

    parts.append("PRINT 'Loaded. Try: SELECT * FROM v_map_plan;';\n")
    return "\n".join(parts)


def emit_csv(t, pal, outdir):
    os.makedirs(outdir, exist_ok=True)
    data = dict(t)
    data.update(pal)
    for name, rows in data.items():
        with open(os.path.join(outdir, name + ".csv"), "w", newline="") as f:
            for r in rows:
                f.write("|".join("" if v is None else str(v) for v in r) + "\n")
    with open(os.path.join(outdir, "_bulk_load.sql"), "w") as f:
        for name in data:
            f.write(
                f"BULK INSERT {name} FROM '{os.path.abspath(outdir)}/{name}.csv'\n"
                f"WITH (FIELDTERMINATOR='|', ROWTERMINATOR='0x0a', "
                f"KEEPNULLS, TABLOCK);\n")
    return len(data)


# ---------------------------------------------------------------- entry point

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("wad")
    ap.add_argument("map", nargs="?")
    ap.add_argument("-o", "--out", default=None)
    ap.add_argument("--csv", metavar="DIR")
    ap.add_argument("--schema", default="doom_schema.sql")
    ap.add_argument("--tex-schema", default="doom_textures.sql")
    ap.add_argument("--no-textures", action="store_true",
                    help="skip texture extraction (geometry only)")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()

    wad = Wad(a.wad)
    if a.list or not a.map:
        print(f"{a.wad}: {wad.kind}, {len(wad.directory)} lumps")
        print("maps:", " ".join(wad.maps()))
        return

    t = parse_map(wad, a.map)
    pal = parse_palette(wad)
    for k in ("vertex", "linedef", "sidedef", "sector", "seg", "subsector",
              "node", "thing"):
        print(f"  {k:<10} {len(t[k]):>6}", file=sys.stderr)

    if a.csv:
        n = emit_csv(t, pal, a.csv)
        print(f"wrote {n} CSVs + _bulk_load.sql to {a.csv}", file=sys.stderr)
        return

    textures = None
    if not a.no_textures:
        warn = []
        tex, tex_rows, col_rows = emit_textures(wad, t, warn)
        textures = (tex_rows, col_rows)
        texels = sum(x[2] * x[3] for x in tex)
        print(f"  {'texture':<10} {len(tex_rows):>6}  "
              f"({len(col_rows)} columns, {texels:,} texels)", file=sys.stderr)
        for msg in warn:
            print(f"  warn: {msg}", file=sys.stderr)

    out = a.out or f"{a.map}.sql"
    sql = emit_sql(t, pal, a.map, os.path.basename(a.wad), a.schema,
                   textures, a.tex_schema)
    with open(out, "w") as f:
        f.write(sql)
    print(f"wrote {out} ({os.path.getsize(out)/1024:.0f} KB)", file=sys.stderr)


if __name__ == "__main__":
    main()
