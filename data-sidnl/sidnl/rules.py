"""Vocabulary management: dynamic brand discovery, automated learning from feeds & titles,
suggestion of category noise words, and re-flagging rows. No hardcoding of brands required."""
import re
from collections import Counter, defaultdict
from .common import load_yaml
from .normalize import clean, compact

_CORP_SUFFIXES = re.compile(
    r"\b(pvt\s+ltd|private\s+limited|ltd|inc|llc|corp|corporation|co|company|enterprises|india)\b",
    re.I,
)


def clean_brand_name(brand_raw, ignore=()):
    """Normalize a brand string: removes legal entities (Pvt Ltd, LLC, etc.), punctuation, and leading/trailing noise."""
    if not brand_raw:
        return ""
    s = clean(brand_raw)
    s = _CORP_SUFFIXES.sub(" ", s)
    s = re.sub(r"\s+", " ", s).strip()
    if s in ignore or len(s) < 2 or s.isdigit():
        return ""
    return s


def extract_brand_candidate_from_title(title, noise_set=frozenset(), known_brands=None):
    """When a platform provides no brand metadata, extract the candidate brand from the title.
    In e-commerce catalogs, the brand almost universally appears in the first 1-2 words."""
    if not title:
        return ""
    toks = clean(title).split()
    if not toks:
        return ""
    # 1. Match against known brands if available (longest match first)
    if known_brands:
        for n in range(min(4, len(toks)), 0, -1):
            cand = " ".join(toks[:n])
            if cand in known_brands or cand.replace(" ", "") in known_brands:
                return cand

    # 2. Extract leading non-digit, non-noise words
    cand_toks = []
    for t in toks[:3]:
        if t.isdigit() or t in noise_set or any(c.isdigit() for c in t):
            break
        cand_toks.append(t)
        if len(cand_toks) == 2:  # Most brand names are 1 or 2 tokens (e.g. Dove, Samsung, Coca Cola, Thums Up)
            break
    return " ".join(cand_toks)


def seed(conn, cfg=None):
    """Seed standard physical units, variant synonyms, noise words, and any optional manual brand aliases into DB."""
    cfg = cfg or load_yaml("matching.yaml")
    with conn.cursor() as cur:
        # Physical units (constants)
        cur.executemany(
            "insert into sidnl.ref_unit values (%s,%s,%s) on conflict do nothing",
            [(k.lower(), v[0], v[1]) for k, v in cfg.get("units", {}).items()],
        )
        # Optional manual brand aliases (if any configured)
        brand_aliases = cfg.get("brand_aliases") or {}
        if brand_aliases:
            cur.executemany(
                "insert into sidnl.ref_brand_alias (alias_key, brand, source) values (%s,%s,'manual') on conflict do nothing",
                sorted({(clean(a), canon) for canon, al in brand_aliases.items() for a in set(al + [canon]) if clean(a)}),
            )
        # Variant synonyms
        cur.executemany(
            "insert into sidnl.ref_variant_synonym (syn_key, variant) values (%s,%s) on conflict do nothing",
            sorted({(clean(s), canon) for canon, syns in cfg.get("variants", {}).items() for s in syns if clean(s)}),
        )
        # Noise words
        cur.executemany(
            "insert into sidnl.ref_noise_word (word) values (%s) on conflict do nothing",
            sorted({(clean(w),) for w in cfg.get("noise_words", []) if clean(w)}),
        )
    conn.commit()


# ---- pure functions (unit-testable without a database) -----------------------------------------------------------
def aggregate_brands(rows, min_count=2, ignore=()):
    """rows: iterable of (brand_raw, n). Spellings that differ only in spacing/punctuation/legal suffixes are merged;
    the dominant spelling becomes the display name. Returns {alias_key: (display, n)}."""
    ignore_set = {clean(i) for i in ignore}
    groups = defaultdict(lambda: defaultdict(int))
    for raw, n in rows:
        k = clean_brand_name(raw, ignore_set)
        if not k:
            continue
        groups[k.replace(" ", "")][k] += n
    out = {}
    for spellings in groups.values():
        if sum(spellings.values()) < min_count:
            continue
        display = max(spellings.items(), key=lambda kv: (kv[1], len(kv[0])))[0]
        for s, n in spellings.items():
            out[s] = (display, n)
            out[s.replace(" ", "")] = (display, n)
    return out


def noise_candidates(rows, min_group=200, min_df=0.30, skip=frozenset()):
    """rows: iterable of (category, name). A token present in >= min_df of a category's names carries no information
    inside that category. Returns {token: max_df}. These are only SUGGESTIONS."""
    groups = defaultdict(lambda: [0, Counter()])
    for cat, name in rows:
        g = groups[cat]
        g[0] += 1
        g[1].update({t for t in clean(name).split() if len(t) > 1 and not any(c.isdigit() for c in t)})
    out = {}
    for n, cnt in groups.values():
        if n < min_group:
            continue
        for t, c in cnt.items():
            if t not in skip and c / n >= min_df:
                out[t] = max(out.get(t, 0.0), c / n)
    return out


# ---- database side ------------------------------------------------------------------------------------------------
def auto_register_brands(conn, brands_dict):
    """Dynamically register newly discovered brands into ref_brand_alias during ingestion or streaming."""
    if not brands_dict:
        return
    with conn.cursor() as cur:
        cur.executemany(
            """insert into sidnl.ref_brand_alias as r (alias_key, brand, source, n) values (%s,%s,'auto',%s)
               on conflict (alias_key) do update set n = r.n + excluded.n
               where r.source = 'auto'""",
            [(clean(k), display, n) for k, (display, n) in brands_dict.items() if clean(k)],
        )
    conn.commit()


def learn(conn, cfg=None):
    """Dynamic brand and vocabulary learning across all ingested e-commerce platforms."""
    cfg = cfg or load_yaml("matching.yaml")
    L = cfg.get("learn", {})
    min_count = L.get("min_brand_count", 2)
    ignore = L.get("ignore_brands", ["na", "none", "generic"])
    with conn.cursor() as cur:
        # 1. Discover brands from platforms' brand_raw column
        cur.execute("select brand_raw, count(*) from sidnl.source_products where brand_raw is not null group by 1")
        brand_rows = list(cur.fetchall())

        # 2. Also sample unbranded product names to extract brand prefixes
        cur.execute(
            "select name, count(*) from sidnl.source_products "
            "where (brand_raw is null or brand_raw = '') and name is not null group by 1 limit 50000"
        )
        cur.execute("select word from sidnl.ref_noise_word where active")
        noise_set = {w for (w,) in cur.fetchall()}

        for name, cnt in cur.fetchall():
            cand = extract_brand_candidate_from_title(name, noise_set)
            if cand:
                brand_rows.append((cand, cnt))

        brands = aggregate_brands(brand_rows, min_count, ignore)
        cur.executemany(
            """insert into sidnl.ref_brand_alias as r (alias_key, brand, source, n) values (%s,%s,'auto',%s)
               on conflict (alias_key) do update set brand = excluded.brand, n = excluded.n
               where r.source = 'auto'""",
            [(k, d, n) for k, (d, n) in brands.items()],
        )

        cur.execute("select reltuples::bigint from pg_class where oid = 'sidnl.source_products'::regclass")
        res = cur.fetchone()
        est = max(res[0] if res else 1, 1)
        sample_rows = L.get("noise_sample_rows", 300000)
        pct = min(100.0, max(0.01, sample_rows / est * 100))
        cur.execute(
            "select syn_key from sidnl.ref_variant_synonym union select alias_key from sidnl.ref_brand_alias "
            "union select word from sidnl.ref_noise_word"
        )
        skip = {t for (k,) in cur.fetchall() for t in k.split()}
    conn.commit()

    with conn.cursor(name="learn_sample") as cur:
        cur.itersize = 10_000
        cur.execute(
            f"select category_raw, name from sidnl.source_products tablesample system ({pct:.4f}) "
            "where category_raw is not null and name is not null"
        )
        cands = noise_candidates(cur, L.get("noise_group_min_rows", 200), L.get("noise_min_df", 0.30), skip)
    with conn.cursor() as cur:
        cur.executemany(
            """insert into sidnl.ref_noise_word as r (word, source, score, active) values (%s,'auto',%s,false)
               on conflict (word) do update set score = excluded.score where r.source = 'auto' and not r.active""",
            list(cands.items()),
        )
    conn.commit()
    return len(brands), len(cands)


def suggest(conn, limit=50):
    with conn.cursor() as cur:
        cur.execute(
            "select word, score from sidnl.ref_noise_word where source='auto' and not active "
            "order by score desc limit %s",
            (limit,),
        )
        return cur.fetchall()


def activate(conn, words):
    """Approve noise words, and flag only the products that contain them for re-normalisation."""
    words = [clean(w) for w in words if clean(w)]
    with conn.cursor() as cur:
        cur.execute("update sidnl.ref_noise_word set active = true where word = any(%s)", (words,))
        for w in words:
            cur.execute("update sidnl.source_products set needs_normalize = true where lower(name) like %s", (f"%{w}%",))
    conn.commit()


def renormalize(conn, platform=None):
    """Use after editing ref_* tables by hand."""
    with conn.cursor() as cur:
        if platform:
            cur.execute("update sidnl.source_products set needs_normalize = true where platform = %s", (platform,))
        else:
            cur.execute("update sidnl.source_products set needs_normalize = true")
        n = cur.rowcount
    conn.commit()
    return n
