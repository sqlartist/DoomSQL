#!/usr/bin/env python3
"""
wadsprite.py -- sprite lumps and the thing -> sprite mapping.

Two problems, neither of them decoding (that's the same patch format the wall
textures use).

1. LUMP NAMING. Sprite lumps encode frame and rotation in the name:
       TROOA1      sprite TROO, frame A, rotation 1
       TROOA2A8    the same picture serves rotation 2, and rotation 8 MIRRORED
       BAR1A0      rotation 0 means "looks the same from every angle"
   Rotation runs 1-8 anticlockwise from the front.

2. WHICH SPRITE. A thing in the WAD is a number -- 3001 is an imp. The map
   from number to sprite lives in Doom's info.c, which is source code, not
   data. The table below is that mapping for vanilla things, with the frame
   each one spawns in (monsters spawn in frame A; corpses and some props
   spawn part-way through their animation).
"""

import struct
from wadtex import decode_patch

# doomednum -> (sprite, frame letter, full_bright)
MOBJ = {
    # monsters
    3004: ('POSS','A',0), 9:    ('SPOS','A',0), 3001: ('TROO','A',0),
    3002: ('SARG','A',0), 58:   ('SARG','A',0), 3006: ('SKUL','A',1),
    3005: ('HEAD','A',0), 3003: ('BOSS','A',0), 69:   ('BOS2','A',0),
    68:   ('BSPI','A',0), 71:   ('PAIN','A',0), 66:   ('SKEL','A',0),
    67:   ('FATT','A',0), 64:   ('VILE','A',0), 65:   ('CPOS','A',0),
    7:    ('SPID','A',0), 16:   ('CYBR','A',0), 84:   ('SSWV','A',0),
    72:   ('KEEN','A',0), 88:   ('BBRN','A',0),
    # weapons
    2001: ('SHOT','A',0), 82:   ('SGN2','A',0), 2002: ('MGUN','A',0),
    2003: ('LAUN','A',0), 2004: ('PLAS','A',0), 2005: ('CSAW','A',0),
    2006: ('BFUG','A',0),
    # ammo
    2007: ('CLIP','A',0), 2048: ('AMMO','A',0), 2010: ('ROCK','A',0),
    2046: ('BROK','A',0), 2047: ('CELL','A',0), 17:   ('CELP','A',0),
    2008: ('SHEL','A',0), 2049: ('SBOX','A',0), 8:    ('BPAK','A',0),
    # health and powerups
    2011: ('STIM','A',0), 2012: ('MEDI','A',0), 2014: ('BON1','A',1),
    2015: ('BON2','A',1), 2018: ('ARM1','A',1), 2019: ('ARM2','A',1),
    83:   ('MEGA','A',1), 2013: ('SOUL','A',1), 2022: ('PINV','A',1),
    2023: ('PSTR','A',1), 2024: ('PINS','A',1), 2025: ('SUIT','A',1),
    2026: ('PMAP','A',1), 2045: ('PVIS','A',1),
    # keys
    5:    ('BKEY','A',1), 40:   ('BSKU','A',1), 13:   ('RKEY','A',1),
    38:   ('RSKU','A',1), 6:    ('YKEY','A',1), 39:   ('YSKU','A',1),
    # obstacles and decor
    2035: ('BAR1','A',0), 72+0: ('KEEN','A',0),
    48:   ('ELEC','A',0), 30:   ('COL1','A',0), 31:   ('COL2','A',0),
    32:   ('COL3','A',0), 33:   ('COL4','A',0), 37:   ('COL6','A',0),
    36:   ('COL5','A',0), 41:   ('CEYE','A',1), 42:   ('FSKU','A',1),
    43:   ('TRE1','A',0), 54:   ('TRE2','A',0), 2028: ('COLU','A',1),
    35:   ('CBRA','A',1), 34:   ('CAND','A',1), 44:   ('TBLU','A',1),
    45:   ('TGRN','A',1), 46:   ('TRED','A',1), 55:   ('SMBT','A',1),
    56:   ('SMGT','A',1), 57:   ('SMRT','A',1), 47:   ('SMIT','A',0),
    70:   ('FCAN','A',1), 73:   ('HDB1','A',0), 74:   ('HDB2','A',0),
    75:   ('HDB3','A',0), 76:   ('HDB4','A',0), 77:   ('HDB5','A',0),
    78:   ('HDB6','A',0), 79:   ('POB1','A',0), 80:   ('POB2','A',0),
    81:   ('BRS1','A',0), 85:   ('TLMP','A',1), 86:   ('TLP2','A',1),
    # corpses and gore -- these spawn part-way through their animation
    10:   ('PLAY','W',0), 12:   ('PLAY','W',0), 15:   ('PLAY','N',0),
    18:   ('POSS','L',0), 19:   ('SPOS','L',0), 20:   ('TROO','M',0),
    21:   ('SARG','N',0), 22:   ('HEAD','L',0), 23:   ('SKUL','K',0),
    24:   ('POL5','A',0), 25:   ('POL1','A',0), 26:   ('POL6','A',0),
    27:   ('POL4','A',0), 28:   ('POL2','A',0), 29:   ('POL3','A',1),
    49:   ('GOR1','A',0), 50:   ('GOR2','A',0), 51:   ('GOR3','A',0),
    52:   ('GOR4','A',0), 53:   ('GOR5','A',0), 59:   ('GOR2','A',0),
    60:   ('GOR4','A',0), 61:   ('GOR3','A',0), 62:   ('GOR5','A',0),
    63:   ('GOR1','A',0),
}

# things that exist but are never drawn
NON_VISIBLE = {1, 2, 3, 4, 11, 14, 87, 89}      # player starts, teleport dest

# The player's own weapon sprites. These are not map things -- nothing in the
# WAD references them -- so they are named explicitly or they never get
# extracted. G = the weapon itself, F = its muzzle flash.
WEAPON_SPRITES = {'PUNG','SAWG','PISG','PISF','SHTG','SHTF','CHGG','CHGF',
                  'MISG','MISF','PLSG','PLSF','BFGG','BFGF'}


def sprite_index(wad):
    """name -> lump index for everything between the sprite markers."""
    out, depth = {}, 0
    for i, (name, _pos, size) in enumerate(wad.directory):
        if name in ('S_START', 'SS_START'):
            depth += 1
            continue
        if name in ('S_END', 'SS_END'):
            depth = max(0, depth - 1)
            continue
        if depth > 0 and size > 0:
            out.setdefault(name, i)
    return out


def parse_lump_name(name):
    """'TROOA2A8' -> [('TROO','A',2,False), ('TROO','A',8,True)]"""
    out = []
    if len(name) < 6:
        return out
    sprite = name[0:4]
    out.append((sprite, name[4], name[5], False))
    if len(name) >= 8:
        out.append((sprite, name[6], name[7], True))
    return [(s, f, int(r), fl) for (s, f, r, fl) in out
            if f.isalpha() and r.isdigit()]


def decode_patch_full(blob):
    """Like decode_patch but keeps the offsets, which sprites need: they say
    where the picture hangs relative to the thing's position and floor."""
    w, h, left, top = struct.unpack_from('<hhhh', blob, 0)
    _w, _h, cols = decode_patch(blob)
    return w, h, left, top, cols


def wanted_sprites(things):
    """Only the sprites this map's things actually reference."""
    need = set()
    for t in things:
        typ = t[4]
        if typ in NON_VISIBLE:
            continue
        m = MOBJ.get(typ)
        if m:
            need.add((m[0], m[1]))
    return need


def extract(wad, things, warn=None):
    """-> (frames, unknown_types)

    frames: {(sprite, frame, rotation): dict(w,h,left,top,flip,cols)}
    """
    warn = warn if warn is not None else []
    idx = sprite_index(wad)
    need = wanted_sprites(things)
    need_sprites = {s for s, _f in need} | WEAPON_SPRITES

    # every lump belonging to a sprite we need, indexed by frame and rotation
    frames = {}
    for name, lump in idx.items():
        parsed = parse_lump_name(name)
        if not parsed or parsed[0][0] not in need_sprites:
            continue
        try:
            w, h, left, top, cols = decode_patch_full(wad.lump(lump))
        except (ValueError, struct.error) as e:
            warn.append(f'sprite {name}: {e}')
            continue
        for (sprite, frame, rot, flip) in parsed:
            frames[(sprite, frame, rot)] = dict(
                w=w, h=h, left=left, top=top, flip=flip, cols=cols, lump=name)

    unknown = sorted({t[4] for t in things
                      if t[4] not in NON_VISIBLE and t[4] not in MOBJ})
    for (s, f) in sorted(need):
        if not any(k[0] == s and k[1] == f for k in frames):
            warn.append(f'no lump for sprite {s} frame {f}')
    for s in sorted(WEAPON_SPRITES):
        if not any(k[0] == s for k in frames):
            warn.append(f'no lumps at all for weapon sprite {s}')
    return frames, unknown


def pick_rotation(frames, sprite, frame, view_angle_deg, thing_angle_deg,
                  angle_to_thing_deg):
    """Doom's R_ProjectSprite rotation choice. Rotation 0 means the sprite
    looks the same from every direction; otherwise pick one of 8 based on
    where the viewer is standing relative to the thing's facing."""
    if (sprite, frame, 0) in frames:
        return frames[(sprite, frame, 0)]
    rel = (angle_to_thing_deg - thing_angle_deg + 202.5) % 360
    rot = int(rel / 45.0) + 1
    got = frames.get((sprite, frame, rot))
    if got is None:                       # incomplete rotation set
        for r in range(1, 9):
            got = frames.get((sprite, frame, r))
            if got:
                break
    return got
