"""Silver layer: Comprehensive Data Preprocessing, Normalization & Feature Extraction.

PREPROCESSING PIPELINE:
1. Text Sanitization: HTML unescaping (&amp; -> &, &quot; -> ", &#39; -> '), Unicode NFKD normalization
   (accents, fancy quotes, emojis), vulgar fractions (½ -> 0.5), and contraction cleaning (Lay's -> lays).
2. Physical Grammar Normalization: Extracts size, unit conversions (physical constants: 1 L -> 1000 ml,
   1 kg -> 1000 g), fractional sizes (1/2 kg -> 500 g), and pack counts ("6 x 330 ml", "pack of 4").
3. Hierarchical Category Parsing: Cleans breadcrumbs ("Beauty > Hair Care > Shampoo") into standardized (L1, L2, L3).
4. Dynamic Brand Normalization & Extraction: Zero hardcoded brands. Cleans corporate suffixes (Pvt Ltd, LLC, Inc),
   discovers brands from platform metadata and title prefixes, and maintains O(1) in-memory lookup.
5. Tokenization & Canonicalization: Strips noise words, uninformative tokens, and forms order-invariant canonical strings.
"""
import html, os, re, unicodedata
from concurrent.futures import ProcessPoolExecutor
from .common import connect

_NUM = r"(\d+(?:\s*/\s*\d+|[.,]\d+)?)"
_PACK = re.compile(r"(?:pack of|set of|combo of)\s*(\d+)|(\d+)\s*(?:pcs|pc|cans|bottles|units)\b", re.I)
_THOUSANDS = re.compile(r"^\d{1,3}(?:,\d{3})+$")

_CORP_SUFFIXES = re.compile(
    r"\b(pvt\s+ltd|private\s+limited|ltd|inc|llc|corp|corporation|co|company|enterprises|india)\b",
    re.I,
)

_CAT_DELIMS = re.compile(r"\s*(?:>|->|/|\||-|;)\s*")

_FRACTIONS = {
    "½": " 0.5 ",
    "¼": " 0.25 ",
    "¾": " 0.75 ",
    "⅓": " 0.33 ",
    "⅔": " 0.67 ",
}


# ====================================================================================================
# PREPROCESSING TECHNIQUE 1: Text Sanitization & Unicode Normalization
# ====================================================================================================
def clean(s):
    """Sanitize raw e-commerce text:
    - HTML entity decoding (&amp; -> and, &quot; -> ", &#39; -> ')
    - Unicode NFKD normalization (replaces accents like é -> e, strips zero-width spaces)
    - Vulgar fraction expansion (½ -> 0.5)
    - Contraction & possessive flattening (Lay's -> lays, Women's -> womens)
    - Non-alphanumeric replacement with single whitespace
    """
    if not s:
        return ""
    # Step 1: Decode HTML entities
    s = html.unescape(str(s))
    # Step 2: Unicode normalization (decomposes accents and standardizes symbols)
    s = unicodedata.normalize("NFKD", s)
    # Step 3: Expand vulgar unicode fractions
    for frac, dec in _FRACTIONS.items():
        if frac in s:
            s = s.replace(frac, dec)
    # Step 4: Lowercase and standardize conjunctions
    s = s.lower().replace("&", " and ")
    # Step 5: Contractions (apostrophes, backticks, curved quotes removed to avoid word fragmentation)
    s = re.sub(r"['’`]", "", s)
    # Step 6: Non-alphanumeric symbols to single space
    s = re.sub(r"[\W_]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def compact(s):
    """Brand identity representation: strips all whitespace to equate 'Thums Up' == 'ThumsUp' == 'thums-up'."""
    return clean(s).replace(" ", "")


# ====================================================================================================
# PREPROCESSING TECHNIQUE 2: Brand Cleaning & Corporate Entity Removal
# ====================================================================================================
def clean_brand_name(brand_raw, ignore=()):
    """Normalize raw brand text: strips legal corporate entities (Pvt Ltd, LLC, Inc),
    punctuation, and non-informative markers."""
    if not brand_raw:
        return ""
    s = clean(brand_raw)
    s = _CORP_SUFFIXES.sub(" ", s)
    s = re.sub(r"\s+", " ", s).strip()
    if s in ignore or len(s) < 2 or s.isdigit():
        return ""
    return s


# ====================================================================================================
# PREPROCESSING TECHNIQUE 3: Hierarchical Category Breadcrumb Parsing
# ====================================================================================================
def parse_category(category_raw):
    """Parse hierarchical category path into standardized 3-level taxonomy (L1, L2, L3).
    Example: 'Beauty > Hair Care > Shampoo' -> ('beauty', 'hair care', 'shampoo')"""
    if not category_raw:
        return None, None, None
    parts = [clean(p) for p in _CAT_DELIMS.split(str(category_raw)) if clean(p)]
    l1 = parts[0] if len(parts) > 0 else None
    l2 = parts[1] if len(parts) > 1 else None
    l3 = parts[2] if len(parts) > 2 else (parts[-1] if len(parts) > 2 else None)
    return l1, l2, l3


# ====================================================================================================
# PREPROCESSING TECHNIQUE 4: Numerical & Fractional String Conversion
# ====================================================================================================
def _to_float(s):
    """Parse numeric strings handling European decimal commas ('0,33'), US thousands ('1,000'),
    and fractions ('1/2')."""
    s = s.strip()
    if "/" in s:
        parts = s.split("/")
        try:
            return float(parts[0].strip()) / float(parts[1].strip())
        except (ValueError, ZeroDivisionError):
            return 0.0
    if _THOUSANDS.match(s):
        return float(s.replace(",", ""))
    return float(s.replace(",", "."))


def _remove_seq(toks, seq):
    """Remove exact sequence of tokens from list."""
    n = len(seq)
    if not n:
        return toks
    out, i = [], 0
    while i < len(toks):
        if toks[i:i + n] == seq:
            i += n
        else:
            out.append(toks[i]); i += 1
    return out


# ====================================================================================================
# PREPROCESSING TECHNIQUE 5: Tokenization & Structured Attribute Extraction (Lexicon)
# ====================================================================================================
class Lexicon:
    DEFAULT_IGNORE_BRANDS = frozenset([
        "na", "n a", "none", "null", "generic", "others", "other",
        "unbranded", "no brand", "unknown", "not applicable"
    ])

    def __init__(self, units, brands=None, variants=None, noise=None, ignore_brands=None):
        if not units:
            raise ValueError("no units configured - run `python -m sidnl.cli seed-rules`")
        self.units = {k.lower(): (b, float(f)) for k, (b, f) in units.items()}
        alt = "|".join(re.escape(k) for k in sorted(self.units, key=len, reverse=True))
        self._rx = ((re.compile(rf"(\d+)\s*[x×*]\s*{_NUM}\s*({alt})\b", re.I), "pn"),     # 6 x 330 ml
                    (re.compile(rf"{_NUM}\s*({alt})\s*[x×*]\s*(\d+)\b", re.I), "np"),     # 330 ml x 6
                    (re.compile(rf"{_NUM}\s*({alt})\b", re.I), "n"))                       # 330ml / 0.33 L
        self.brands = {}
        self._bn = 1
        self.ignore_brands = set(ignore_brands or self.DEFAULT_IGNORE_BRANDS)
        for key, display, anywhere in sorted(brands or [], key=lambda b: not b[2]):
            self.register_brand(key, display, anywhere)
        self.variants = {clean(k): v for k, v in (variants or {}).items() if clean(k)}
        self.noise = {clean(w) for w in (noise or ())}
        self._bn = min(5, max((len(k.split()) for k in self.brands), default=1))
        self._vn = min(5, max((len(k.split()) for k in self.variants), default=1))

    def register_brand(self, key, display=None, anywhere=False):
        """Dynamically add a brand to in-memory lookup table in O(1)."""
        k = clean(key)
        if not k or k in self.ignore_brands:
            return
        disp = display or k
        entry = (compact(disp), bool(anywhere))
        self.brands.setdefault(k, entry)
        ck = k.replace(" ", "")
        if len(ck) >= 3:
            self.brands.setdefault(ck, entry)
        self._bn = min(5, max(self._bn, len(k.split())))

    @classmethod
    def from_db(conn_cls, conn):
        with conn.cursor() as cur:
            cur.execute("select unit_key, base_unit, factor from sidnl.ref_unit")
            units = {k: (b, f) for k, b, f in cur.fetchall()}
            cur.execute("select alias_key, brand, source = 'manual' from sidnl.ref_brand_alias where active")
            brands = cur.fetchall()
            cur.execute("select syn_key, variant from sidnl.ref_variant_synonym where active")
            variants = dict(cur.fetchall())
            cur.execute("select word from sidnl.ref_noise_word where active")
            noise = {w for (w,) in cur.fetchall()}
        conn.commit()
        return conn_cls(units, brands, variants, noise)

    @classmethod
    def from_yaml(cls, cfg):
        units = {k: tuple(v) for k, v in cfg.get("units", {}).items()}
        raw_aliases = cfg.get("brand_aliases") or {}
        brands = [(a, canon, True) for canon, al in raw_aliases.items() for a in set(al + [canon])]
        variants = {s: canon for canon, syns in cfg.get("variants", {}).items() for s in syns}
        noise = cfg.get("noise_words", [])
        ignore = cfg.get("learn", {}).get("ignore_brands")
        return cls(units, brands, variants, noise, ignore)

    def parse_size(self, *texts):
        """Parse size, base unit, and pack count from raw text."""
        for t in texts:
            if not t:
                continue
            t = str(t)
            for rx, order in self._rx:
                m = rx.search(t)
                if not m:
                    continue
                g = m.groups()
                if order == "pn":   pack, num, u = int(g[0]), g[1], g[2]
                elif order == "np": num, u, pack = g[0], g[1], int(g[2])
                else:               num, u, pack = g[0], g[1], 1
                base, factor = self.units[u.lower()]
                if pack == 1:
                    for tt in texts:
                        pm = _PACK.search(str(tt)) if tt else None
                        if pm:
                            pack = int(pm.group(1) or pm.group(2)); break
                return round(_to_float(num) * factor, 2), base, pack
        return None, None, 1

    def _strip_size(self, text):
        low = text.lower()
        for rx, _ in self._rx:
            low = rx.sub(" ", low)
        return _PACK.sub(" ", low)

    @staticmethod
    def _scan(toks, table, maxn):
        """Longest-match-first n-gram scanner."""
        hits, i, L = [], 0, len(toks)
        while i < L:
            for n in range(min(maxn, L - i), 0, -1):
                v = table.get(" ".join(toks[i:i + n]))
                if v is not None:
                    hits.append((i, i + n, v)); i += n
                    break
            else:
                i += 1
        return hits

    def features(self, name, brand_raw=None, size_raw=None, category_raw=None):
        """Transform raw product listing into normalized, canonical structured features."""
        name = "" if name is None else str(name)
        size, base, pack = self.parse_size(size_raw, name)
        l1, l2, l3 = parse_category(category_raw)

        # Tokenize after stripping extracted size text
        toks = clean(self._strip_size(name)).split()

        # Dynamic brand discovery & extraction
        braw = clean_brand_name(brand_raw, self.ignore_brands)
        hits = self._scan(toks, self.brands, self._bn)
        ident = ""

        if braw:
            known = self.brands.get(braw) or self.brands.get(braw.replace(" ", ""))
            if known:
                ident = known[0]
            else:
                ident = compact(braw)
                self.register_brand(braw, ident, anywhere=False)
        else:
            # Infer from known brands or title tokens
            matched_brand = next((bid for i, j, (bid, anywhere) in hits if anywhere or i == 0), "")
            if matched_brand:
                ident = matched_brand
            elif toks and len(self.brands) == 0:
                cand = toks[0]
                if cand not in self.noise and not cand.isdigit() and len(cand) >= 2:
                    ident = compact(cand)
                    self.register_brand(cand, ident, anywhere=False)

        # Remove brand occurrences from tokens
        if ident:
            if not hits:
                hits = self._scan(toks, self.brands, self._bn)
            drop = {k for i, j, (bid, _) in hits if bid == ident for k in range(i, j)}
            L = len(toks)
            for n in range(min(4, L), 0, -1):
                for i in range(L - n + 1):
                    if compact(" ".join(toks[i:i + n])) == ident:
                        drop.update(range(i, i + n))
            toks = [t for k, t in enumerate(toks) if k not in drop]
            if braw:
                toks = [t for t in _remove_seq(toks, braw.split()) if t != braw.replace(" ", "")]

        # Extract semantic variants (colours, editions, formulations)
        found, drop = set(), set()
        for i, j, v in self._scan(toks, self.variants, self._vn):
            found.add(v); drop.update(range(i, j))
        toks = [t for k, t in enumerate(toks) if k not in drop]

        # PREPROCESSING: Filter noise/stopwords and produce sorted canonical token string
        name_clean = " ".join(sorted({t for t in toks if t not in self.noise and not t.isdigit() and len(t) > 1}))

        return {
            "brand": ident,
            "size_base": size,
            "size_unit": base,
            "pack_count": pack,
            "variant": "|".join(sorted(found)),
            "category_l1": l1,
            "category_l2": l2,
            "category_l3": l3,
            "name_clean": name_clean,
        }


# ====================================================================================================
# BATCH WORKER
# ====================================================================================================
_UPSERT = """insert into sidnl.product_features select * from _pf order by source_id
             on conflict (source_id) do update set
               brand=excluded.brand,
               size_base=excluded.size_base, size_unit=excluded.size_unit,
               pack_count=excluded.pack_count, variant=excluded.variant,
               category_l1=excluded.category_l1, category_l2=excluded.category_l2,
               category_l3=excluded.category_l3, name_clean=excluded.name_clean"""


def _worker(batch):
    conn = connect()
    lex = Lexicon.from_db(conn)
    total = 0
    while True:
        with conn.cursor() as cur:
            cur.execute("""select source_id, name, brand_raw, size_raw, category_raw
                           from sidnl.source_products
                           where needs_normalize order by source_id limit %s for update skip locked""", (batch,))
            rows = cur.fetchall()
            if not rows:
                break
            out = []
            new_brands = {}
            for sid, name, brand, size, cat in rows:
                f = lex.features(name, brand, size, cat)
                out.append((sid, f["brand"], f["size_base"], f["size_unit"], f["pack_count"],
                            f["variant"], f["category_l1"], f["category_l2"], f["category_l3"], f["name_clean"]))
                if f["brand"] and f["brand"] not in lex.brands:
                    new_brands[f["brand"]] = new_brands.get(f["brand"], 0) + 1

            cur.execute("create temp table _pf (like sidnl.product_features) on commit drop")
            with cur.copy("copy _pf (source_id,brand,size_base,size_unit,pack_count,variant,"
                          "category_l1,category_l2,category_l3,name_clean) from stdin") as cp:
                for r in out:
                    cp.write_row(r)
            cur.execute(_UPSERT)

            if new_brands:
                cur.executemany("""insert into sidnl.ref_brand_alias as r (alias_key, brand, source, n)
                                   values (%s,%s,'auto',%s)
                                   on conflict (alias_key) do update set n = r.n + excluded.n
                                   where r.source = 'auto'""",
                                [(k, k, n) for k, n in new_brands.items()])

            ids = [r[0] for r in out]
            cur.execute("delete from sidnl.product_map where source_id = any(%s) and status <> 'MANUAL'", (ids,))
            cur.execute("update sidnl.source_products set needs_normalize=false where source_id = any(%s)", (ids,))
        conn.commit()
        total += len(rows)
    conn.commit()
    conn.close()
    return total


def run(batch=20_000, workers=None):
    workers = workers or int(os.environ.get("SIDNL_WORKERS", min(os.cpu_count() or 1, 4)))
    if workers <= 1:
        total = _worker(batch)
    else:
        with ProcessPoolExecutor(workers) as ex:
            total = sum(ex.map(_worker, [batch] * workers))
    if total:
        print(f"normalized {total:,}")
    return total
