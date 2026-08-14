#!/usr/bin/env python3
"""
render_ref.py -- reference implementation of the SQL rasteriser.

Deliberately not idiomatic Python: every stage is a set of tuples transformed
by an operation with a direct SQL equivalent, so doom_render.sql is a
transliteration of this and the two can be diffed.

  stage 1  view transform     projection arithmetic in a SELECT
  stage 2  near clip + cull    WHERE + CASE
  stage 3  seg x column        JOIN numbers
  stage 4  order by depth      ORDER BY within PARTITION BY x
  stage 5  occlusion           MAX/MIN OVER (PARTITION BY x ORDER BY depth
                                             ROWS UNBOUNDED PRECEDING .. 1 PRECEDING)
  stage 6  spans -> rows       JOIN numbers
  stage 7  texel fetch         JOIN texture_column + SUBSTRING
  stage 8  shade               JOIN v_palette_rgb

THE THING TO UNDERSTAND: Doom maintains ceilingclip/floorclip arrays
imperatively as it walks the BSP front to back. Those are prefix scans. The
clip bounds in force when a seg is drawn are the running MAX and MIN of every
nearer seg's opening in that column -- a window frame, not a mutable array.

Because the clip bounds are exact, no pixel is written twice and there is no
z-buffer at all. An earlier version used a per-pixel argmin instead and it was
wrong: a distant room's ceiling plane is nearer than the one you are standing
under, so it won the argmin and painted over everything. Planes need
visibility, not just depth.
"""
import math
import sys
from PIL import Image

from wad2sql import Wad, parse_map, parse_palette
import wadtex
import wadsprite

W, H = 320, 200
CX, CY = W / 2.0, H / 2.0
PROJ = 160.0            # 90 degree horizontal FOV
NEAR = 4.0
EYE = 41.0
LIGHT_FALLOFF = 280.0   # world units per colormap step

LF_UPPER_UNPEG = 0x0008
LF_LOWER_UNPEG = 0x0010

SKY = "F_SKY1"


def load(wadfile, mapname):
    wad = Wad(wadfile)
    t = parse_map(wad, mapname)
    pal = parse_palette(wad)
    tex = wadtex.extract(wad, t)

    m = {}
    m["vertex"] = {v[0]: (v[1], v[2]) for v in t["vertex"]}
    m["sector"] = {s[0]: dict(floor=s[1], ceil=s[2], floor_tex=s[3],
                              ceil_tex=s[4], light=s[5]) for s in t["sector"]}
    m["sidedef"] = {s[0]: dict(xoff=s[1], yoff=s[2], upper=s[3], lower=s[4],
                               middle=s[5], sector=s[6]) for s in t["sidedef"]}
    m["linedef"] = {l[0]: dict(flags=l[3], right=l[6], left=l[7])
                    for l in t["linedef"]}
    m["seg"] = t["seg"]
    m["seg_sector"] = {s[0]: (s[1], s[2]) for s in t["seg_sector"]}
    m["node"] = {n[0]: n for n in t["node"]}
    m["subsector"] = {s[0]: s for s in t["subsector"]}
    m["thing"] = t["thing"]

    m["texture"] = {}
    m["texture_column"] = {}
    for tid, (name, kind, tw, th, masked, cols) in enumerate(tex):
        m["texture"][name] = dict(id=tid, w=tw, h=th, masked=masked)
        for u, pixels, alpha in cols:
            m["texture_column"][(tid, u)] = (pixels, alpha)

    m["sprite_frame"], m["unknown_things"] = wadsprite.extract(wad, t["thing"])

    playpal = {(p, i): (r, g, b) for (p, i, r, g, b) in pal["playpal"]}
    m["palette_rgb"] = {(lvl, i): playpal[(0, o)]
                        for (lvl, i, o) in pal["colormap"]}
    return m


def subsector_at(m, px, py):
    idx, is_leaf = max(m["node"]), False
    while not is_leaf:
        n = m["node"][idx]
        side = (px - n[1]) * n[4] - (py - n[2]) * n[3]
        # right child when the point is on the right (positive) side
        is_leaf, idx = (n[13], n[14]) if side > 0 else (n[15], n[16])
    return idx


def sector_at(m, px, py):
    ss = subsector_at(m, px, py)
    return m["seg_sector"][m["subsector"][ss][1]][0]


def clampl(v):
    return 0 if v < 0 else (31 if v > 31 else int(v))


# ---------------------------------------------------------------- the pipeline

def project_segs(m, px, py, ang):
    """Stages 1-3: every (seg, screen column) that survives cull and clip."""
    cos_a, sin_a = math.cos(ang), math.sin(ang)
    cols = [[] for _ in range(W)]

    for (sid, sv1, sv2, sangle, ldid, side, offset_u) in m["seg"]:
        x1, y1 = m["vertex"][sv1]
        x2, y2 = m["vertex"][sv2]

        # backface cull: the front side is right of v1->v2
        if (px - x1) * (y2 - y1) - (py - y1) * (x2 - x1) <= 0:
            continue

        tx1, ty1 = x1 - px, y1 - py
        tx2, ty2 = x2 - px, y2 - py
        z1 = tx1 * cos_a + ty1 * sin_a
        z2 = tx2 * cos_a + ty2 * sin_a
        l1 = tx1 * sin_a - ty1 * cos_a
        l2 = tx2 * sin_a - ty2 * cos_a

        u1, u2 = 0.0, math.hypot(x2 - x1, y2 - y1)

        if z1 < NEAR and z2 < NEAR:
            continue
        if z1 < NEAR:
            t = (NEAR - z1) / (z2 - z1)
            l1 += (l2 - l1) * t
            u1 += (u2 - u1) * t
            z1 = NEAR
        elif z2 < NEAR:
            t = (NEAR - z2) / (z1 - z2)
            l2 += (l1 - l2) * t
            u2 += (u1 - u2) * t
            z2 = NEAR

        sx1 = CX + PROJ * l1 / z1
        sx2 = CX + PROJ * l2 / z2
        if sx2 <= sx1 or sx2 < 0 or sx1 > W - 1:
            continue

        ld = m["linedef"][ldid]
        sd_id = ld["right"] if side == 0 else ld["left"]
        if sd_id is None:
            continue
        sd = m["sidedef"][sd_id]
        front_id, back_id = m["seg_sector"][sid]
        if front_id is None:
            continue
        fs = m["sector"][front_id]
        bs = m["sector"][back_id] if back_id is not None else None
        # NOTE: a closed portal is NOT turned into a solid wall here. A shut
        # door is a two-sided line whose ceiling has come down to its floor,
        # and its art lives on the UPPER texture -- door sidedefs almost never
        # have a middle. Treating it as solid drew the (absent) middle and
        # left a hole. The degenerate opening closes the column by itself.

        info = (sd, fs, bs, ld["flags"], sd["yoff"], 31 - fs["light"] // 8)

        base_u = offset_u + sd["xoff"]
        inv_z1, inv_z2 = 1.0 / z1, 1.0 / z2
        uz1, uz2 = u1 * inv_z1, u2 * inv_z2
        for x in range(max(0, int(math.ceil(sx1))),
                       min(W - 1, int(math.floor(sx2))) + 1):
            t = (x - sx1) / (sx2 - sx1)
            inv_z = inv_z1 + (inv_z2 - inv_z1) * t
            if inv_z <= 0:
                continue
            u_world = base_u + (uz1 + (uz2 - uz1) * t) / inv_z
            cols[x].append((inv_z, u_world, info))
    return cols


def render(m, px, py, ang, viewz):
    cols = project_segs(m, px, py, ang)
    fb = [[None] * W for _ in range(H)]      # (pal_idx, light)
    prgb = m["palette_rgb"]
    tcol = m["texture_column"]
    tinfo = m["texture"]
    cos_a, sin_a = math.cos(ang), math.sin(ang)

    def wall_span(x, ya, yb, ceil_clip, floor_clip, texname, origin_h,
                  u_world, inv_z, yoff, light):
        ti = tinfo.get(texname)
        if ti is None:
            return
        col = tcol.get((ti["id"], int(u_world) % ti["w"]))
        if col is None:
            return
        pixels, alpha = col
        z = 1.0 / inv_z
        for y in range(max(ceil_clip, int(math.ceil(ya))),
                       min(floor_clip, int(math.floor(yb))) + 1):
            h_world = viewz + (CY - y) * z / PROJ
            v = int(origin_h - h_world + yoff) % ti["h"]
            if alpha is not None and alpha[v] == 0:
                continue
            fb[y][x] = (pixels[v], light)

    def plane_span(x, y0, y1, h_plane, texname, light_base):
        if texname == SKY:
            return
        ti = tinfo.get(texname)
        if ti is None:
            return
        dh = viewz - h_plane
        for y in range(y0, y1 + 1):
            denom = y - CY
            if denom == 0 or (dh > 0) != (denom > 0):
                continue
            zf = dh * PROJ / denom
            if zf < NEAR:
                continue
            lat = (x - CX) * zf / PROJ
            wx = px + cos_a * zf + sin_a * lat
            wy = py + sin_a * zf - cos_a * lat
            col = tcol.get((ti["id"], int(wx) % ti["w"]))
            if col is None:
                continue
            fb[y][x] = (col[0][int(wy) % ti["h"]],
                        clampl(light_base + zf / LIGHT_FALLOFF))

    # Per-column record of what the walls did, so sprites can be clipped
    # against it afterwards. In SQL this is a table the wall pass writes and
    # the sprite pass aggregates over.
    colrec = [[] for _ in range(W)]        # (inv_z, y_otop, y_obot, is_solid)

    for x in range(W):
        # ---- stage 4: front to back. bsp_order() gives this ordering without
        # computing depth at all; sorting by inv_z is the same thing per column.
        run = sorted(cols[x], key=lambda r: -r[0])

        # ---- stage 5: the prefix scan. In SQL these are
        # MAX/MIN OVER (PARTITION BY x ORDER BY depth
        #               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
        ceil_clip, floor_clip = 0, H - 1

        for inv_z, u_world, (sd, fs, bs, flags, yoff, light_base) in run:
            if ceil_clip > floor_clip:
                break                          # column fully closed
            light = clampl(light_base + (1.0 / inv_z) / LIGHT_FALLOFF)

            y_ceil = CY - (fs["ceil"] - viewz) * PROJ * inv_z
            y_floor = CY - (fs["floor"] - viewz) * PROJ * inv_z

            # ---- front sector's planes, bounded by the running clip
            if fs["ceil"] > viewz:
                plane_span(x, ceil_clip,
                           min(floor_clip, int(math.ceil(y_ceil)) - 1),
                           fs["ceil"], fs["ceil_tex"], light_base)
            if fs["floor"] < viewz:
                plane_span(x, max(ceil_clip, int(math.floor(y_floor)) + 1),
                           floor_clip, fs["floor"], fs["floor_tex"], light_base)

            if bs is None:
                th = tinfo.get(sd["middle"], {}).get("h", 128)
                origin = (fs["floor"] + th) if (flags & LF_LOWER_UNPEG) else fs["ceil"]
                wall_span(x, y_ceil, y_floor, ceil_clip, floor_clip,
                          sd["middle"], origin, u_world, inv_z, yoff, light)
                colrec[x].append((inv_z, 0.0, float(H - 1), 1))
                ceil_clip, floor_clip = 1, 0   # column closed
                continue

            # ---- portal: the opening narrows the clip for everything behind
            open_top = min(fs["ceil"], bs["ceil"])
            open_bot = max(fs["floor"], bs["floor"])
            shut = open_top <= open_bot
            y_open_top = CY - (open_top - viewz) * PROJ * inv_z
            y_open_bot = CY - (open_bot - viewz) * PROJ * inv_z

            if bs["ceil"] < fs["ceil"] and sd["upper"] != "-":
                th = tinfo.get(sd["upper"], {}).get("h", 128)
                origin = fs["ceil"] if (flags & LF_UPPER_UNPEG) else (bs["ceil"] + th)
                # with no opening the upper covers the whole wall: stopping at
                # the opening top would leave the one row where top meets
                # bottom unpainted
                y_bottom = y_floor if shut else math.ceil(y_open_top) - 1
                wall_span(x, y_ceil, y_bottom,
                          ceil_clip, floor_clip,
                          sd["upper"], origin, u_world, inv_z, yoff, light)
            if bs["floor"] > fs["floor"] and sd["lower"] != "-":
                origin = fs["ceil"] if (flags & LF_LOWER_UNPEG) else bs["floor"]
                wall_span(x, math.floor(y_open_bot) + 1, y_floor,
                          ceil_clip, floor_clip,
                          sd["lower"], origin, u_world, inv_z, yoff, light)

            colrec[x].append((inv_z, y_open_top, y_open_bot, 0))
            ceil_clip = max(ceil_clip, int(math.ceil(y_open_top)))
            floor_clip = min(floor_clip, int(math.floor(y_open_bot)))

    # ---- sprites. Drawn after the walls, back to front, clipped against
    # what the wall pass recorded. Doom clips sprites against drawsegs; here
    # the equivalent is: for a sprite at depth d in column x, aggregate every
    # NEARER seg in that column -- if any was solid the sprite is hidden, and
    # otherwise the running MAX/MIN of their openings is the window it shows
    # through. Same prefix aggregation as the walls, ranged on depth instead
    # of ordered by it.
    draw_sky(m, fb, ang)
    draw_sprites(m, fb, colrec, px, py, ang, viewz)

    # ---- stage 8: shade
    img = Image.new("RGB", (W, H), (0, 0, 0))
    put = img.putpixel
    for y in range(H):
        row = fb[y]
        for x in range(W):
            c = row[x]
            if c is not None:
                put((x, y), prgb[(c[1], c[0])])
    return img


def draw_sky(m, fb, ang):
    """Sky fills whatever no surface claimed. It has no depth and no
    perspective: the column depends only on where you are looking, and the
    row is the screen row.

    Doom maps a full turn to 1024 sky columns (a 32-bit BAM angle shifted
    right by 22), then wraps into a 256-wide texture -- so the sky repeats
    four times around you rather than once. Vertically dc_texturemid is 100
    at unit scale, which reduces to texture row = screen row.
    """
    ti = m["texture"].get("SKY1")
    if ti is None:
        return
    tcol = m["texture_column"]
    for x in range(W):
        # angle of this screen column, then Doom's 1024-per-turn mapping
        a = ang + math.atan2(CX - x, PROJ)
        # floor, not int(): the column angle goes negative on the right half
        # of the screen and int() truncates toward zero, which breaks the wrap
        u = math.floor((a / (2 * math.pi)) * 1024) % ti["w"]
        col = tcol.get((ti["id"], u))
        if col is None:
            continue
        pixels = col[0]
        for y in range(H):
            if fb[y][x] is not None:
                continue
            # clamp rather than wrap: Doom only ever draws sky above the
            # horizon, so a repeat below row 128 would be an artefact
            v = y if y < ti["h"] else ti["h"] - 1
            fb[y][x] = (pixels[v], 0)             # sky is always full bright


def draw_sprites(m, fb, colrec, px, py, ang, viewz):
    cos_a, sin_a = math.cos(ang), math.sin(ang)
    view_deg = math.degrees(ang)
    frames = m["sprite_frame"]

    # project every visible thing
    vis = []
    for (tid, tx, ty, tang, ttype, tflags) in m["thing"]:
        if ttype in wadsprite.NON_VISIBLE:
            continue
        info = wadsprite.MOBJ.get(ttype)
        if info is None:
            continue
        if tflags & 16:                     # multiplayer-only
            continue
        dx, dy = tx - px, ty - py
        z = dx * cos_a + dy * sin_a
        if z < NEAR:
            continue
        lat = dx * sin_a - dy * cos_a
        ang_to = math.degrees(math.atan2(dy, dx))
        fr = wadsprite.pick_rotation(frames, info[0], info[1],
                                     view_deg, float(tang), ang_to)
        if fr is None:
            continue
        sec = m["sector"][sector_at(m, tx, ty)]
        vis.append((z, lat, fr, sec, info[2]))

    # back to front: nearer sprites overwrite further ones
    for (z, lat, fr, sec, fullbright) in sorted(vis, key=lambda v: -v[0]):
        inv_z = 1.0 / z
        scale = PROJ * inv_z
        cx_screen = CX + PROJ * lat * inv_z

        # the patch offsets say where the picture hangs: left of centre by
        # `left`, and `top` above the thing's feet
        x0 = cx_screen - fr["left"] * scale
        y0 = CY - (sec["floor"] + fr["top"] - viewz) * scale
        w_px = fr["w"] * scale
        h_px = fr["h"] * scale
        if w_px < 1 or h_px < 1:
            continue

        light = 0 if fullbright else clampl(31 - sec["light"] // 8
                                            + z / LIGHT_FALLOFF)

        for x in range(max(0, int(x0)), min(W - 1, int(x0 + w_px)) + 1):
            # clip against every nearer seg in this column
            hidden = False
            ctop, cbot = 0, H - 1
            for (wz, otop, obot, solid) in colrec[x]:
                if wz <= inv_z:             # further away than the sprite
                    continue
                if solid:
                    hidden = True
                    break
                ctop = max(ctop, int(math.ceil(otop)))
                cbot = min(cbot, int(math.floor(obot)))
            if hidden or ctop > cbot:
                continue

            u = int((x - x0) / scale)
            if fr["flip"]:
                u = fr["w"] - 1 - u
            if u < 0 or u >= fr["w"]:
                continue
            col = fr["cols"][u]

            for y in range(max(ctop, int(y0)), min(cbot, int(y0 + h_px)) + 1):
                v = int((y - y0) / scale)
                if v < 0 or v >= fr["h"]:
                    continue
                px_idx = col[v]
                if px_idx is None:          # transparent
                    continue
                fb[y][x] = (px_idx, light)


def main():
    wadfile = sys.argv[1]
    mapname = sys.argv[2] if len(sys.argv) > 2 else "E1M1"
    out = sys.argv[3] if len(sys.argv) > 3 else "frame.png"
    turn = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0

    m = load(wadfile, mapname)
    start = next(th for th in m["thing"] if th[4] == 1)
    px, py = float(start[1]), float(start[2])
    ang = math.radians(start[3] + turn)
    sec = sector_at(m, px, py)
    viewz = m["sector"][sec]["floor"] + EYE
    print(f"  ({px:.0f},{py:.0f}) angle {start[3] + turn:.0f} "
          f"sector {sec} viewz {viewz:.0f}")

    img = render(m, px, py, ang, viewz)
    img.resize((W * 3, int(H * 3 * 1.2)), Image.NEAREST).save(out)
    print(f"  wrote {out}")


if __name__ == "__main__":
    main()
