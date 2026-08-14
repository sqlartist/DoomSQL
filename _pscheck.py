"""Catch the PowerShell parsing traps I keep hitting, since there is no pwsh
here to do it properly. Not a parser -- a checklist of known failure modes."""
import re, sys

CMDLETS = ('Write-Host','Write-Output','Write-Error','Add-Type','New-Object',
           'Join-Path','Get-Location','Invoke-Proc','Set-Key','Get-Frame',
           'Out-Null','Write-Verbose','Start-Sleep')

def check(path):
    src = open(path).read()
    lines = src.split('\n')
    problems = []

    # 1. argument-mode concatenation: a command call whose argument list
    #    contains a bare + outside parentheses
    for i, ln in enumerate(lines, 1):
        code = re.sub(r'#.*$', '', ln)
        for c in CMDLETS:
            m = re.search(rf'(?<![\w-]){re.escape(c)}\s+(.*)$', code)
            if not m: continue
            args = m.group(1)
            depth = 0; instr = False; q = ''
            for ch in args:
                if instr:
                    if ch == q: instr = False
                    continue
                if ch in '"\'': instr, q = True, ch
                elif ch in '([': depth += 1
                elif ch in ')]': depth -= 1
                elif ch == '+' and depth <= 0:
                    problems.append(f'{path}:{i}  bare + in {c} arguments -- parenthesise')
                    break

    # 2. unbalanced braces / parens / brackets overall
    depth = {'{':0, '(':0, '[':0}
    pairs = {'}':'{', ')':'(', ']':'['}
    instr = False; q = ''; prev = ''
    for ch in re.sub(r'#[^\n]*', '', src):
        if instr:
            if ch == q and prev != '`': instr = False
            prev = ch; continue
        if ch in '"\'': instr, q = True, ch
        elif ch in depth: depth[ch] += 1
        elif ch in pairs: depth[pairs[ch]] -= 1
        prev = ch
    for k, v in depth.items():
        if v: problems.append(f'{path}  unbalanced {k}: {v:+d}')

    # 3. $script: assignment inside a scriptblock without the prefix, for the
    #    variables that must persist across event handlers
    persistent = ('frame','frames','totalMs','busy','keys')
    for i, ln in enumerate(lines, 1):
        for v in persistent:
            if re.search(rf'^\s*\${v}\s*=', ln) and 'param' not in ln:
                # only a problem inside a scriptblock; flag for review
                pass

    # 4. lines sitting at column 0 while nested inside a scriptblock. A
    #    string replacement that matched more occurrences than intended
    #    splices unindented text into the middle of a block, and PowerShell
    #    parses it happily -- it just does the wrong thing.
    depth, instr, q = 0, False, ''
    for i, ln in enumerate(lines, 1):
        stripped = ln.strip()
        if depth > 0 and stripped and not ln.startswith((' ', '\t')) \
           and not stripped.startswith(('}', '#', ')')) \
           and not stripped.startswith('$form') \
           and not stripped.startswith('function'):
            problems.append(f'{path}:{i}  unindented line inside a block '
                            f'(depth {depth}) -- likely a bad splice: '
                            f'{stripped[:40]}')
        code = re.sub(r'#.*$', '', ln)
        code = re.sub(r"'[^']*'", '', code)
        depth += code.count('{') - code.count('}')

    # 5. Add_X handlers that reference an undefined variable name
    src_nc = re.sub(r'#[^\n]*', '', src)   # comments are not code
    defined = set(re.findall(r'\$(?:script:)?(\w+)\s*=', src))
    defined |= set(re.findall(r'\[\w+\]\$(\w+)', src))
    defined |= set(re.findall(r'foreach\s*\(\s*\$(\w+)\s+in', src, re.I))
    defined |= set(re.findall(r'function\s+[\w-]+\s*\(([^)]*)\)',
                              src, re.I | re.S) and
                   re.findall(r'\$(\w+)',
                              ' '.join(re.findall(r'function\s+[\w-]+\s*\(([^)]*)\)',
                                                  src, re.I | re.S))) or [])
    defined |= set(re.findall(r'param\s*\(([^)]*)\)', src, re.I | re.S) and
                   re.findall(r'\$(\w+)',
                              ' '.join(re.findall(r'param\s*\(([^)]*)\)',
                                                  src, re.I | re.S))) or [])
    defined |= {'_','PSItem','sender','e','true','false','null','args','Out'}
    used = set(re.findall(r'\$(?:script:)?(\w+)', src_nc))
    unknown = {u for u in used - defined if not u[0].isupper()}
    if unknown:
        problems.append(f'{path}  possibly undefined: {sorted(unknown)}')

    return problems

bad = []
for p in sys.argv[1:]:
    bad += check(p)
print('\n'.join('  ' + b for b in bad) if bad else '  no known-trap patterns found')
