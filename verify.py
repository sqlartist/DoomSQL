#!/usr/bin/env python3
"""Prove the schema holds and that the recursive-CTE ordering trick is sound.

The T-SQL bsp_order() function can't do depth-first recursion the way
R_RenderBSPNode does, so it walks breadth-first and builds a path string
('0' = near child, '1' = far child). The claim is that lexical order on
that path is identical to depth-first near-first traversal order.

This checks that claim against a real map, from several viewpoints.
"""
import sys
from wad2sql import Wad, parse_map

wad = Wad(sys.argv[1])
mp = sys.argv[2] if len(sys.argv) > 2 else "E1M1"
t = parse_map(wad, mp)

verts = {v[0] for v in t["vertex"]}
sects = {s[0] for s in t["sector"]}
sides = {s[0] for s in t["sidedef"]}
lines = {l[0] for l in t["linedef"]}
segs = {s[0] for s in t["seg"]}
subs = {s[0] for s in t["subsector"]}
nodes = {n[0] for n in t["node"]}

fails = []


def check(label, bad):
    if bad:
        fails.append(f"{label}: {len(bad)} violations e.g. {list(bad)[:3]}")
    print(f"  {'FAIL' if bad else 'ok  '}  {label}")


check("linedef.v1/v2 -> vertex",
      [l for l in t["linedef"] if l[1] not in verts or l[2] not in verts])
check("linedef.sidedefs -> sidedef",
      [l for l in t["linedef"]
       if (l[6] is not None and l[6] not in sides)
       or (l[7] is not None and l[7] not in sides)])
check("sidedef.sector_id -> sector",
      [s for s in t["sidedef"] if s[6] not in sects])
check("seg.linedef_id -> linedef",
      [s for s in t["seg"] if s[4] not in lines])
check("seg.v1/v2 -> vertex",
      [s for s in t["seg"] if s[1] not in verts or s[2] not in verts])
check("subsector seg range -> seg",
      [s for s in t["subsector"] if s[1] not in segs or s[2] not in segs])
check("node children -> node/subsector",
      [n for n in t["node"]
       if (n[13] and n[14] not in subs) or (not n[13] and n[14] not in nodes)
       or (n[15] and n[16] not in subs) or (not n[15] and n[16] not in nodes)])
check("every seg belongs to a subsector",
      segs - {i for s in t["subsector"] for i in range(s[1], s[2] + 1)})

# ------------------------------------------------------------------ BSP order
node = {n[0]: n for n in t["node"]}
root = max(nodes)


def classic(px, py):
    """What R_RenderBSPNode does: depth-first, near child first."""
    out, stack = [], [(False, root)]
    while stack:
        is_leaf, idx = stack.pop()
        if is_leaf:
            out.append(idx)
            continue
        n = node[idx]
        side = (px - n[1]) * n[4] - (py - n[2]) * n[3]
        near = (n[13], n[14]) if side > 0 else (n[15], n[16])
        far = (n[15], n[16]) if side > 0 else (n[13], n[14])
        stack.append(far)
        stack.append(near)
    return out


def path_sort(px, py):
    """What the recursive CTE does: breadth-first, then ORDER BY path."""
    leaves, frontier = [], [(False, root, "")]
    while frontier:
        nxt = []
        for is_leaf, idx, path in frontier:
            if is_leaf:
                leaves.append((path, idx))
                continue
            n = node[idx]
            side = (px - n[1]) * n[4] - (py - n[2]) * n[3]
            near = (n[13], n[14]) if side > 0 else (n[15], n[16])
            far = (n[15], n[16]) if side > 0 else (n[13], n[14])
            nxt.append((bool(near[0]), near[1], path + "0"))
            nxt.append((bool(far[0]), far[1], path + "1"))
        frontier = nxt
    return [idx for _, idx in sorted(leaves)]


starts = [(th[1], th[2]) for th in t["thing"] if th[4] == 1]
probes = starts + [(0, 0), (2048, -2048), (-1024, 512), (512, -3600)]
mismatch = 0
for px, py in probes:
    a, b = classic(px, py), path_sort(px, py)
    if a != b:
        mismatch += 1
check(f"BSP path-sort == depth-first order ({len(probes)} viewpoints)",
      ["viewpoint mismatch"] * mismatch)
check("BSP walk reaches every subsector",
      subs - set(classic(*probes[0])))

# deepest leaf, to size the CTE recursion guard
_leaves, _frontier = [], [(False, root, "")]
while _frontier:
    _nxt = []
    for is_leaf, idx, path in _frontier:
        if is_leaf:
            _leaves.append(path)
            continue
        n = node[idx]
        _nxt.append((bool(n[13]), n[14], path + "0"))
        _nxt.append((bool(n[15]), n[16], path + "1"))
    _frontier = _nxt
print(f"\n  max BSP depth: {max(len(p) for p in _leaves)} "
      f"(recursion limit in the CTE is 48, SQL Server default MAXRECURSION 100)")
print(f"  subsectors: {len(subs)}, segs: {len(segs)}, nodes: {len(nodes)}")

print()
if fails:
    print("FAILURES:")
    for f in fails:
        print("  " + f)
    sys.exit(1)
print("all checks passed")
