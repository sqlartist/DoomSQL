#!/usr/bin/env python3
"""Render the parsed map as an SVG: floorplan + BSP front-to-back order.

Left panel  : what v_map_plan shows in SSMS's spatial tab.
Right panel : segs coloured by dbo.bsp_order() visit rank from the player
              start -- cool = drawn first (nearest), warm = drawn last.
"""
import sys
from wad2sql import Wad, parse_map

wad = Wad(sys.argv[1])
mp = sys.argv[2] if len(sys.argv) > 2 else "E1M1"
out = sys.argv[3] if len(sys.argv) > 3 else "plan.svg"
t = parse_map(wad, mp)

V = {v[0]: (v[1], v[2]) for v in t["vertex"]}
xs = [p[0] for p in V.values()]
ys = [p[1] for p in V.values()]
pad = 64
minx, maxx, miny, maxy = min(xs) - pad, max(xs) + pad, min(ys) - pad, max(ys) + pad
W = maxx - minx
H = maxy - miny
SCALE = 900.0 / max(W, H)
PW, PH = W * SCALE, H * SCALE


def P(x, y):
    return (x - minx) * SCALE, (maxy - y) * SCALE   # Doom y is up, SVG y is down


# --- BSP order from the player start -----------------------------------
node = {n[0]: n for n in t["node"]}
root = max(node)
px, py = next((th[1], th[2]) for th in t["thing"] if th[4] == 1)
order, stack = [], [(False, root)]
while stack:
    leaf, idx = stack.pop()
    if leaf:
        order.append(idx)
        continue
    n = node[idx]
    s = (px - n[1]) * n[4] - (py - n[2]) * n[3]
    near, far = ((n[13], n[14]), (n[15], n[16])) if s > 0 else ((n[15], n[16]), (n[13], n[14]))
    stack += [far, near]
rank = {ss: i / max(1, len(order) - 1) for i, ss in enumerate(order)}

seg_rank = {}
for ss in t["subsector"]:
    for sid in range(ss[1], ss[2] + 1):
        seg_rank[sid] = rank.get(ss[0], 0)


def heat(u):
    r = int(255 * min(1, u * 1.6))
    g = int(90 + 60 * (1 - abs(u - 0.5) * 2))
    b = int(255 * min(1, (1 - u) * 1.6))
    return f"#{r:02x}{g:02x}{b:02x}"


parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{PW*2+40:.0f}" '
         f'height="{PH+50:.0f}" viewBox="0 0 {PW*2+40:.0f} {PH+50:.0f}">',
         '<rect width="100%" height="100%" fill="#0b0d10"/>',
         f'<text x="10" y="24" fill="#8a94a6" font-family="monospace" '
         f'font-size="15">{mp} — v_map_plan (walls / portals)</text>',
         f'<text x="{PW+50:.0f}" y="24" fill="#8a94a6" font-family="monospace" '
         f'font-size="15">bsp_order() from player start — near to far</text>',
         '<g transform="translate(0,40)">']

for l in t["linedef"]:
    x1, y1 = P(*V[l[1]])
    x2, y2 = P(*V[l[2]])
    solid = l[7] is None
    col = "#d8dee9" if solid else "#3f4757"
    w = 1.6 if solid else 0.9
    parts.append(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" '
                 f'stroke="{col}" stroke-width="{w}"/>')
sx, sy = P(px, py)
parts.append(f'<circle cx="{sx:.1f}" cy="{sy:.1f}" r="6" fill="none" '
             f'stroke="#4ade80" stroke-width="2"/>')

parts.append(f'</g><g transform="translate({PW+40:.0f},40)">')
for s in t["seg"]:
    x1, y1 = P(*V[s[1]])
    x2, y2 = P(*V[s[2]])
    parts.append(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" '
                 f'stroke="{heat(seg_rank.get(s[0], 0))}" stroke-width="1.6"/>')
parts.append(f'<circle cx="{sx:.1f}" cy="{sy:.1f}" r="6" fill="none" '
             f'stroke="#ffffff" stroke-width="2"/>')
parts.append('</g></svg>')

with open(out, "w") as f:
    f.write("\n".join(parts))
print(f"{out}: {len(t['linedef'])} linedefs, {len(order)} subsectors ordered")
