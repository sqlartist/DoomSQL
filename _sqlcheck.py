"""Detect Msg 8156 (duplicate output column) across a CTE chain.

The naive approach -- regex every alias.column in the SELECT clause -- counts
references inside expressions as output columns and produces nonsense. This
splits the select list on TOP-LEVEL commas and works out each item's output
name properly, which is the only way to get it right.
"""
import re, sys

def base_tables(files):
    t = {}
    for f in files:
        for m in re.finditer(r'CREATE TABLE dbo\.(\w+) \(\n(.*?)\n\);',
                             open(f).read(), re.S):
            cols = []
            for line in m.group(2).split('\n'):
                mm = re.match(r'\s+(\w+)\s', line)
                if mm and mm.group(1).upper() not in ('CONSTRAINT','PRIMARY'):
                    cols.append(mm.group(1))
            t[m.group(1)] = cols
    t['numbers'] = ['n']
    return t

def strip_comments(s):
    """Comments contain commas and the word FROM; they must go before any
    structural parsing, or the select-list splitter chops them into fragments
    and silently loses the real items next to them."""
    out, i, n = [], 0, len(s)
    instr = False
    while i < n:
        ch = s[i]
        if instr:
            out.append(ch)
            if ch == "'": instr = False
            i += 1; continue
        if ch == "'":
            instr = True; out.append(ch); i += 1; continue
        if s.startswith('/*', i):
            depth = 1; i += 2
            while i < n and depth:
                if s.startswith('/*', i): depth += 1; i += 2
                elif s.startswith('*/', i): depth -= 1; i += 2
                else: i += 1
            out.append(' '); continue
        if s.startswith('--', i):
            while i < n and s[i] != '\n': i += 1
            continue
        out.append(ch); i += 1
    return ''.join(out)


def split_top(s):
    """split on commas not inside brackets or quotes"""
    out, buf, depth, instr = [], '', 0, False
    for ch in s:
        if instr:
            buf += ch
            if ch == "'": instr = False
            continue
        if ch == "'": instr = True; buf += ch; continue
        if ch in '([': depth += 1
        elif ch in ')]': depth -= 1
        if ch == ',' and depth == 0:
            out.append(buf); buf = ''
        else:
            buf += ch
    if buf.strip(): out.append(buf)
    return [x.strip() for x in out]

def select_list(body):
    """text between the leading SELECT and its matching FROM at depth 0"""
    m = re.search(r'\bSELECT\b', body)
    if not m: return ''
    i, depth, instr = m.end(), 0, False
    while i < len(body):
        ch = body[i]
        if instr:
            if ch == "'": instr = False
        elif ch == "'": instr = True
        elif ch in '([': depth += 1
        elif ch in ')]': depth -= 1
        elif depth == 0 and body.startswith('FROM', i) and \
             (i == 0 or not body[i-1].isalnum()):
            return body[m.end():i]
        i += 1
    return body[m.end():]

def out_name(item, avail):
    item = item.strip()
    m = re.match(r'(\w+)\.\*$', item)
    if m: return ('star', m.group(1))
    m = re.match(r'(\w+)\s*=', item)
    if m: return ('name', m.group(1))
    m = re.search(r'\bAS\s+(\w+)\s*$', item, re.I)
    if m: return ('name', m.group(1))
    m = re.match(r'(?:\w+\.)?(\w+)\s*$', item)
    if m: return ('name', m.group(1))
    return ('expr', None)

def analyse(path, schema, marker):
    src = strip_comments(open(path).read())
    proc = src[src.index(marker):]
    bodies, order = {}, []
    for m in re.finditer(
        r'(?:^|;WITH\s+)(\w+) AS \(\s*\n(.*?)\n\s*\),?\s*\n\s*'
        r'(?=\w+ AS \(|INSERT|SELECT)',
        proc, re.S | re.M):
        bodies[m.group(1)] = m.group(2); order.append(m.group(1))

    tables = base_tables(schema)
    cte, problems = {}, []
    for name in order:
        body = bodies[name]
        avail = {}
        for s_, al in re.findall(
                r'(?:FROM|JOIN)\s+(?:dbo\.)?(\w+)\s+(?:AS\s+)?(\w+)\b', body):
            if al.upper() in ('ON','AS','CROSS','WHERE','OUTER','APPLY'): continue
            avail[al] = list(tables.get(s_) or cte.get(s_) or [])
        for inner, al in re.findall(
                r'(?:CROSS|OUTER) APPLY \(\s*SELECT (.*?)\)\s*(\w+)\b', body, re.S):
            cols = [x.strip() for x in re.findall(r'(\w+)\s*=', inner)]
            for st in re.findall(r'(\w+)\.\*', inner):
                cols += tables.get('sprite_frame', [])
            avail[al] = cols

        outs = []
        for item in split_top(select_list(body)):
            kind, val = out_name(item, avail)
            if kind == 'star':  outs += avail.get(val, [])
            elif kind == 'name': outs.append(val)
        seen, dup = set(), []
        for c in outs:
            if c in seen and c not in dup: dup.append(c)
            seen.add(c)
        for d in dup:
            problems.append(f"{name}: duplicate output column '{d}'")
        cte[name] = list(dict.fromkeys(outs))

    print(f'{path} ({marker.split()[-1]}): {len(order)} CTEs')
    print('\n'.join('  ' + p for p in problems) if problems else '  no duplicate output columns')
    return problems

import os
schema = [f for f in ['doom_schema.sql','doom_textures.sql','doom_sprites.sql',
                      'doom_render.sql','doom_sprites_fast.sql'] if os.path.exists(f)]
bad  = analyse('doom_render.sql',  schema, 'CREATE PROCEDURE dbo.render_frame')
bad += analyse('doom_sprites_fast.sql', schema, 'CREATE PROCEDURE dbo.render_sprites')


# ---------------------------------------------------------------------------
def aggregate_subqueries(paths):
    """Msg 130: an aggregate may not contain a subquery. Scans for
    SUM/COUNT/MIN/MAX/AVG whose argument contains a SELECT."""
    AGG = ('SUM','COUNT','MIN','MAX','AVG','STRING_AGG')
    hits = []
    for p in paths:
        src = strip_comments(open(p).read())
        for m in re.finditer(r'\b(' + '|'.join(AGG) + r')\s*\(', src, re.I):
            i, depth = m.end(), 1
            while i < len(src) and depth:
                if src[i] == '(': depth += 1
                elif src[i] == ')': depth -= 1
                i += 1
            arg = src[m.end():i-1]
            if re.search(r'\bSELECT\b', arg, re.I):
                line = src[:m.start()].count('\n') + 1
                hits.append(f'{p}:{line}  {m.group(1)}() contains a subquery (Msg 130)')
    print('\n'.join('  ' + h for h in hits) if hits
          else '  no aggregates containing subqueries')
    return hits

bad += aggregate_subqueries([f for f in
    ['doom_render.sql','doom_sprites_fast.sql','doom_doors.sql','doom_game.sql',
     'doom_present.sql','doom_client.sql','doom_schema.sql','doom_textures.sql',
     'doom_sky.sql','doom_weapons.sql']
    if os.path.exists(f)])


# ---------------------------------------------------------------------------
RESERVED = {
 'add','all','alter','and','any','as','asc','authorization','backup','begin',
 'between','break','browse','bulk','by','cascade','case','check','checkpoint',
 'close','clustered','coalesce','collate','column','commit','compute',
 'constraint','contains','continue','convert','create','cross','current',
 'current_date','current_time','current_timestamp','current_user','cursor',
 'database','dbcc','deallocate','declare','default','delete','deny','desc',
 'disk','distinct','distributed','double','drop','dump','else','end','errlvl',
 'escape','except','exec','execute','exists','exit','external','fetch','file',
 'fillfactor','for','foreign','freetext','from','full','function','goto',
 'grant','group','having','holdlock','identity','if','in','index','inner',
 'insert','intersect','into','is','join','key','kill','left','like','lineno',
 'load','merge','national','nocheck','nonclustered','not','null','nullif','of',
 'off','offsets','on','open','option','or','order','outer','over','percent',
 'pivot','plan','precision','primary','print','proc','procedure','public',
 'raiserror','read','readtext','reconfigure','references','replication',
 'restore','restrict','return','revert','revoke','right','rollback','rowcount',
 'rowguidcol','rule','save','schema','securityaudit','select','session_user',
 'set','setuser','shutdown','some','statistics','system_user','table',
 'tablesample','textsize','then','to','top','tran','transaction','trigger',
 'truncate','tsequal','union','unique','unpivot','update','updatetext','use',
 'user','values','varying','view','waitfor','when','where','while','with',
 'writetext',
 # type keywords that also fail as bare column names
 'bit','int','float','real','char','varchar','text','date','time','datetime',
 'money','image','binary','decimal','numeric','smallint','tinyint','bigint',
}

def reserved_columns(paths):
    hits = []
    for p in paths:
        src = strip_comments(open(p).read())
        for m in re.finditer(r'CREATE TABLE dbo\.(\w+) \(\n(.*?)\n\);', src, re.S):
            for line in m.group(2).split('\n'):
                mm = re.match(r'\s+(\w+)\s+\w', line)
                if mm and mm.group(1).lower() in RESERVED \
                   and mm.group(1).upper() not in ('CONSTRAINT','PRIMARY'):
                    ln = src[:m.start()].count('\n') + 1
                    hits.append(f'{p}  table {m.group(1)}: column '
                                f'"{mm.group(2) if mm.lastindex and mm.lastindex > 1 else mm.group(1)}"'
                                f' is a reserved word (Msg 156)')
    print('\n'.join('  ' + h for h in dict.fromkeys(hits)) if hits
          else '  no reserved words used as column names')
    return hits

bad += reserved_columns([f for f in
    ['doom_schema.sql','doom_textures.sql','doom_sprites.sql','doom_sprites_fast.sql',
     'doom_render.sql','doom_present.sql','doom_game.sql','doom_doors.sql',
     'doom_sky.sql','doom_weapons.sql'] if os.path.exists(f)])
sys.exit(1 if bad else 0)
