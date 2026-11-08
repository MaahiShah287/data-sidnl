#!/usr/bin/env python3
"""Compare repo SQL files with the live migration manifest. Read-only.
Usage: python verify_repo_parity.py LIVE_MIGRATION_MANIFEST.csv path/to/repo/sql/silver [more dirs...]
A repo file matches a migration when its slug (file name without number/extension) is contained in the migration
name, or its leading number equals the number in the name. Match levels: EXACT (md5 of text, trailing newline
tolerated), BODY (leading '--' header removed), COMMENTS-ONLY (all '--' comments removed, whitespace collapsed)."""
import csv, hashlib, re, sys, pathlib
def h(s): return hashlib.md5(s.encode('utf-8')).hexdigest()
def levels(txt):
    t = txt.replace('\r\n', '\n')
    ex = h(t.rstrip('\n')); lines = t.split('\n')
    while lines and (lines[0].startswith('--') or not lines[0].strip()): lines.pop(0)
    body = h('\n'.join(lines).strip(' \n\r\t'))
    cs = h(re.sub(r'\s+', ' ', re.sub(r'[ \t]*--[^\n]*', '', t)).strip(' '))
    return ex, body, cs
rows = list(csv.DictReader(open(sys.argv[1])))
files = [p for d in sys.argv[2:] for p in pathlib.Path(d).rglob('*.sql') if 'rollback' not in p.name]
def key(name):
    m = re.search(r'silver_(\d+[a-z]?)_', name); return m.group(1) if m else None
for r in rows:
    k = key(r['name']); cand = [p for p in files if (k and re.match(rf'^{k}_', p.name)) or r['name'].replace('silver_', '') in p.stem or r['name'] in p.stem]
    if not cand: print(f"MISSING   {r['version']} {r['name']}"); continue
    best = 'DIFF'
    for p in cand:
        ex, body, cs = levels(p.read_text(encoding='utf-8'))
        lvl = 'EXACT' if ex == r['exact_md5'] else 'BODY' if body == r['exact_md5'] else 'COMMENTS-ONLY' if cs == r['comments_stripped_md5'] else 'DIFF'
        if lvl != 'DIFF': best = lvl; break
    print(f"{best:13} {r['version']} {r['name']}  ({cand[0].name})")
