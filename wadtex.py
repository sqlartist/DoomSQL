#!/usr/bin/env python3
"""
wadtex.py -- Doom texture extraction.

Three formats, none of them a bitmap:

  patch     column-major, run-length encoded as "posts" with gaps for
            transparency. This is Doom's picture format.
  texture   a composite: a canvas of W x H assembled from patches placed at
            (originx, originy). Anywhere no patch covers is transparent.
            TEXTURE1 holds the recipe, PNAMES maps patch indices to lumps.
  flat      raw 64x64 palette indices, no header. Used for floors/ceilings.

Output is (pixels, alpha) per texture column: pixels is a bytes of palette
indices, alpha is None if the column is fully opaque, else a 0/1 mask.
"""

import struct

TRANSPARENT = 0


def decode_patch(blob):
    """Doom picture format -> (w, h, columns) where columns[u][v] is an int
    palette index or None for transparent."""
    w, h, _lx, _ty = struct.unpack_from("<hhhh", blob, 0)
    if w <= 0 or h <= 0 or w > 4096 or h > 4096:
        raise ValueError(f"implausible patch dims {w}x{h}")
    offs = struct.unpack_from(f"<{w}I", blob, 8)
    cols = []
    for u in range(w):
        col = [None] * h
        p = offs[u]
        if p >= len(blob):
            cols.append(col)
            continue
        prev_top = -1
        while p < len(blob):
            top = blob[p]
            if top == 0xFF:
                break
            length = blob[p + 1]
            # "tall patch" convention: a topdelta <= the previous one is
            # relative, not absolute. Vanilla maps never hit this; some
            # PWADs do.
            if top <= prev_top:
                top = prev_top + top
            prev_top = top
            data = blob[p + 3: p + 3 + length]      # p+2 is a pad byte
            for i, px in enumerate(data):
                v = top + i
                if 0 <= v < h:
                    col[v] = px
            p += length + 4                          # +1 pad byte at the end
        cols.append(col)
    return w, h, cols


def build_patch_index(wad):
    """name -> lump index. Prefer lumps inside P_START/P_END, but fall back to
    a global search: plenty of PWADs put patches outside the markers."""
    inside, glob = {}, {}
    depth = 0
    for i, (name, _pos, size) in enumerate(wad.directory):
        if name in ("P_START", "PP_START"):
            depth += 1
            continue
        if name in ("P_END", "PP_END"):
            depth = max(0, depth - 1)
            continue
        if size == 0:
            continue
        if depth > 0:
            inside.setdefault(name, i)
        glob.setdefault(name, i)
    return inside, glob


def read_pnames(wad):
    i = wad.find("PNAMES")
    if i is None:
        return []
    blob = wad.lump(i)
    (n,) = struct.unpack_from("<i", blob, 0)
    return [blob[4 + k * 8: 12 + k * 8].split(b"\0")[0]
            .decode("ascii", "replace").upper() for k in range(n)]


def read_texture_defs(wad):
    """name -> (width, height, [(patch_index, originx, originy), ...])"""
    defs = {}
    for lump in ("TEXTURE1", "TEXTURE2"):
        i = wad.find(lump)
        if i is None:
            continue
        blob = wad.lump(i)
        (count,) = struct.unpack_from("<i", blob, 0)
        offsets = struct.unpack_from(f"<{count}i", blob, 4)
        for off in offsets:
            name = blob[off:off + 8].split(b"\0")[0].decode("ascii", "replace").upper()
            w, h = struct.unpack_from("<hh", blob, off + 12)
            (npatch,) = struct.unpack_from("<h", blob, off + 20)
            patches = []
            for k in range(npatch):
                ox, oy, pi = struct.unpack_from("<hhh", blob, off + 22 + k * 10)
                patches.append((pi, ox, oy))
            defs[name] = (w, h, patches)
    return defs


def compose_texture(name, tdef, pnames, wad, inside, glob, cache):
    """R_GenerateComposite, more or less."""
    w, h, patches = tdef
    canvas = [[None] * h for _ in range(w)]
    for pi, ox, oy in patches:
        if pi < 0 or pi >= len(pnames):
            continue
        pname = pnames[pi]
        if pname not in cache:
            idx = inside.get(pname, glob.get(pname))
            if idx is None:
                cache[pname] = None
            else:
                try:
                    cache[pname] = decode_patch(wad.lump(idx))
                except (ValueError, struct.error):
                    cache[pname] = None
        got = cache[pname]
        if got is None:
            continue
        pw, ph, cols = got
        for u in range(pw):
            tu = ox + u
            if not (0 <= tu < w):
                continue
            src = cols[u]
            dst = canvas[tu]
            for v in range(ph):
                tv = oy + v
                if 0 <= tv < h and src[v] is not None:
                    dst[tv] = src[v]
    return w, h, canvas


def flat_index(wad):
    """name -> lump index for everything between the flat markers."""
    out = {}
    depth = 0
    for i, (name, _pos, size) in enumerate(wad.directory):
        if name in ("F_START", "FF_START"):
            depth += 1
            continue
        if name in ("F_END", "FF_END"):
            depth = max(0, depth - 1)
            continue
        if depth > 0 and size > 0:
            out.setdefault(name, i)
    return out


def load_flat(wad, idx):
    """Flats are raw and square: 4096 bytes = 64x64. Returns column-major."""
    blob = wad.lump(idx)
    side = int(len(blob) ** 0.5)
    if side * side != len(blob):
        raise ValueError(f"flat is {len(blob)} bytes, not square")
    return side, side, [[blob[v * side + u] for v in range(side)]
                        for u in range(side)]


def pack_columns(w, h, canvas):
    """canvas[u][v] -> [(u, pixels_bytes, alpha_bytes_or_None)]"""
    out = []
    for u in range(w):
        col = canvas[u]
        px = bytes(TRANSPARENT if c is None else c for c in col)
        if any(c is None for c in col):
            alpha = bytes(0 if c is None else 1 for c in col)
        else:
            alpha = None
        out.append((u, px, alpha))
    return out


def referenced_textures(t):
    """Only the textures this map actually uses. An IWAD has hundreds; a map
    uses a few dozen. This is the difference between 40 MB and 2 MB."""
    walls, flats = set(), set()
    for sd in t["sidedef"]:
        for nm in (sd[3], sd[4], sd[5]):
            if nm and nm != "-":
                walls.add(nm)
    for s in t["sector"]:
        flats.add(s[3])
        flats.add(s[4])
    return walls, flats


def extract(wad, t, warn=None):
    """-> list of (name, kind, w, h, is_masked, [(u, pixels, alpha)])"""
    warn = warn if warn is not None else []
    pnames = read_pnames(wad)
    tdefs = read_texture_defs(wad)
    inside, glob = build_patch_index(wad)
    flats = flat_index(wad)
    cache = {}
    walls_used, flats_used = referenced_textures(t)

    out = []
    for name in sorted(walls_used):
        if name not in tdefs:
            warn.append(f"wall texture {name} not in TEXTURE1/2")
            continue
        w, h, canvas = compose_texture(name, tdefs[name], pnames, wad,
                                       inside, glob, cache)
        cols = pack_columns(w, h, canvas)
        masked = any(a is not None for _, _, a in cols)
        out.append((name, "wall", w, h, masked, cols))

    for name in sorted(flats_used):
        if name not in flats:
            warn.append(f"flat {name} not found between flat markers")
            continue
        try:
            w, h, canvas = load_flat(wad, flats[name])
        except ValueError as e:
            warn.append(f"flat {name}: {e}")
            continue
        out.append((name, "flat", w, h, False, pack_columns(w, h, canvas)))
    return out
