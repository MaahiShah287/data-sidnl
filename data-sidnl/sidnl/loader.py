"""THE write path. Static files and real-time micro-batches both end up in load_df().

DataFrame -> CSV bytes (C speed, no per-row Python) -> COPY into a temp table -> set-based statements.
Only rows that actually CHANGED are written, so a re-run / an unchanged scrape costs reads, not writes.
Dynamically resolves schema & column mappings for ANY e-commerce platform using mathematical pattern matching.
Zero hardcoded platform requirements."""
import functools, os, re
import datetime as dt
import pandas as pd
from .common import load_yaml

CANON = ["platform_product_id", "name", "brand", "size", "category", "url", "price", "mrp", "in_stock", "observed_at"]
COLS = ["platform", "platform_product_id", "name", "brand", "size", "category", "url",
        "price", "mrp", "in_stock", "observed_at", "raw"]

# Algorithmic column resolver patterns for arbitrary data feeds
HEADER_PATTERNS = {
    "platform_product_id": [r"product_?id", r"item_?id", r"sku", r"asin", r"style_?id", r"^id$", r"code"],
    "name": [r"^name$", r"^title$", r"product_?name", r"item_?name", r"product_?title", r"desc"],
    "brand": [r"^brand$", r"brand_?name", r"make", r"manufacturer", r"vendor"],
    "size": [r"^size$", r"^unit$", r"quantity", r"pack_?size", r"volume", r"weight", r"net_?weight", r"^qty$"],
    "category": [r"category", r"cat", r"category_?path", r"breadcrumb", r"department", r"taxonomy"],
    "url": [r"url", r"link", r"href"],
    "price": [r"^price$", r"selling_?price", r"offer_?price", r"sale_?price", r"^sp$"],
    "mrp": [r"^mrp$", r"list_?price", r"original_?price", r"retail_?price"],
    "in_stock": [r"in_?stock", r"^stock$", r"availab", r"is_?in_?stock"],
    "observed_at": [r"observed_?at", r"scraped_?at", r"crawl_?time", r"^timestamp$", r"^date$", r"created_?at", r"updated_?at"],
}


def auto_detect_columns(columns):
    """Dynamically map arbitrary platform headers to canonical attributes using regex heuristics."""
    colmap = {}
    cols_lower = {str(c).lower().strip(): c for c in columns}
    for canon_field, patterns in HEADER_PATTERNS.items():
        for pat in patterns:
            rx = re.compile(pat, re.I)
            match = next((orig for low, orig in cols_lower.items() if rx.search(low)), None)
            if match:
                colmap[canon_field] = match
                break
    return colmap


@functools.lru_cache(maxsize=1)
def platform_cfg():
    try:
        return load_yaml("platforms.yaml")
    except Exception:
        return {"defaults": {"store_raw": True, "true_values": ["1", "true", "yes", "y", "in stock", "available"]}, "platforms": {}}


def prepare(df, colmap=None, true_values=None, default_ts=None, store_raw=True):
    """Vectorised cleaning. Dynamically maps columns if colmap is absent or partial."""
    df = df.reset_index(drop=True)
    true_values = true_values or {"1", "true", "yes", "y", "in stock", "available", "instock"}
    default_ts = default_ts or dt.datetime.now(dt.timezone.utc)

    # Dynamic column mapping
    detected = auto_detect_columns(df.columns)
    effective_colmap = {**detected, **(colmap or {})}

    raw = None
    if store_raw:
        raw = pd.Series(df.to_json(orient="records", lines=True, date_format="iso", force_ascii=False, default_handler=str).splitlines(),
                        index=df.index)

    out = pd.DataFrame(index=df.index)
    for canon in CANON:
        src = effective_colmap.get(canon)
        out[canon] = df[src] if src and src in df.columns else None

    # Fallback product ID generation if platform feed lacks explicit ID
    if out["platform_product_id"].isna().all() and "name" in out.columns:
        out["platform_product_id"] = out.index.astype(str)

    pid = out["platform_product_id"].astype("string").str.strip()
    keep = pid.notna() & (pid != "")
    out = out[keep].copy()
    out["platform_product_id"] = pid[keep]
    out["raw"] = raw[keep] if raw is not None else None

    for c in ("price", "mrp"):
        out[c] = pd.to_numeric(out[c].astype("string").str.replace(r"[^\d.\-]", "", regex=True), errors="coerce")

    s = out["in_stock"].astype("string").str.strip().str.lower()
    out["in_stock"] = s.isin(true_values).astype("boolean").mask(s.isna() | (s == ""))

    ts = pd.to_datetime(out["observed_at"], errors="coerce", utc=True)
    now = pd.Timestamp(default_ts)
    ok = (ts > pd.Timestamp("2000-01-01", tz="UTC")) & (ts < now + pd.Timedelta(days=2))
    out["observed_at"] = ts.where(ok, now)

    for c in ("name", "brand", "size", "category", "url"):
        out[c] = out[c].astype("string").str.strip().replace("", pd.NA)

    return out.drop_duplicates(["platform_product_id", "observed_at"], keep="last")


_STG = """create temp table stg (platform text, platform_product_id text, name text, brand text, size text,
          category text, url text, price numeric, mrp numeric, in_stock boolean, observed_at timestamptz, raw jsonb)
          on commit drop"""

_STEPS = [
    # 1. products: ordered upsert (consistent lock order -> no deadlocks between parallel loaders);
    #    unchanged rows are NOT rewritten (last_seen is refreshed at most once a day).
    """insert into sidnl.source_products as sp
         (platform, platform_product_id, name, brand_raw, size_raw, category_raw, url, raw, content_hash)
       select distinct on (platform, platform_product_id)
              platform, platform_product_id, name, brand, size, category, url, raw,
              md5(coalesce(name,'')||'|'||coalesce(brand,'')||'|'||coalesce(size,'')||'|'||coalesce(category,'')||'|'||coalesce(url,''))
       from stg order by platform, platform_product_id, observed_at desc
       on conflict (platform, platform_product_id) do update set
         name = excluded.name, brand_raw = excluded.brand_raw, size_raw = excluded.size_raw,
         category_raw = excluded.category_raw, url = excluded.url, raw = excluded.raw,
         needs_normalize = sp.needs_normalize or sp.content_hash is distinct from excluded.content_hash,
         content_hash = excluded.content_hash, last_seen = now()
       where sp.content_hash is distinct from excluded.content_hash or sp.last_seen < now() - interval '1 day'""",
    # 2. which observations are real changes?
    """create temp table chg on commit drop as
       with ids as (
         select sp.source_id, s.observed_at, s.price, s.mrp, s.in_stock
         from stg s join sidnl.source_products sp
           on sp.platform = s.platform and sp.platform_product_id = s.platform_product_id),
       seq as (
         select i.*, row_number() over w as rn,
                lag(i.price) over w as p_price, lag(i.mrp) over w as p_mrp, lag(i.in_stock) over w as p_stock
         from ids i window w as (partition by i.source_id order by i.observed_at))
       select q.source_id, q.observed_at, q.price, q.mrp, q.in_stock
       from seq q left join sidnl.offers_latest l on l.source_id = q.source_id
       where (q.rn = 1 and (l.source_id is null or q.observed_at < l.observed_at
                            or (l.price, l.mrp, l.in_stock) is distinct from (q.price, q.mrp, q.in_stock)))
          or (q.rn > 1 and (q.p_price, q.p_mrp, q.p_stock) is distinct from (q.price, q.mrp, q.in_stock))""",
    "insert into sidnl.offers (source_id, observed_at, price, mrp, in_stock) "
    "select source_id, observed_at, price, mrp, in_stock from chg on conflict do nothing",
    """insert into sidnl.offers_latest as l (source_id, observed_at, price, mrp, in_stock)
       select distinct on (source_id) source_id, observed_at, price, mrp, in_stock from chg order by source_id, observed_at desc
       on conflict (source_id) do update set observed_at = excluded.observed_at, price = excluded.price,
         mrp = excluded.mrp, in_stock = excluded.in_stock
       where excluded.observed_at >= l.observed_at""",
    """insert into sidnl.category_map as c (platform, category_raw, seen_count)
       select platform, category, count(*) from stg where category is not null group by 1, 2
       on conflict (platform, category_raw) do update set seen_count = c.seen_count + excluded.seen_count""",
    # 3. Dynamic brand learning: auto-register observed non-empty brands into ref_brand_alias
    """insert into sidnl.ref_brand_alias as r (alias_key, brand, source, n)
       select lower(regexp_replace(trim(brand), '[\W_]+', ' ', 'g')), trim(brand), 'auto', count(*)
       from stg
       where brand is not null and length(trim(brand)) >= 2
         and lower(trim(brand)) not in ('na', 'n a', 'none', 'null', 'generic', 'unbranded', 'no brand')
       group by 1, 2
       on conflict (alias_key) do update set n = r.n + excluded.n
       where r.source = 'auto'""",
]

_ensured = set()


def _ensure_partitions(conn, ts):
    lo, hi = ts.min().tz_convert("UTC").tz_localize(None), ts.max().tz_convert("UTC").tz_localize(None)
    todo = [(p.year, p.month) for p in pd.period_range(lo, hi, freq="M") if (p.year, p.month) not in _ensured]
    if not todo:
        return
    with conn.cursor() as cur:
        for y, m in todo:
            cur.execute("select sidnl.ensure_offer_partition(%s)", (dt.date(y, m, 1),))
    conn.commit()
    _ensured.update(todo)


def load_df(conn, platform, df, cfg=None):
    cfg = cfg or platform_cfg()
    p_info = cfg.get("platforms", {}).get(platform, {})
    colmap = p_info.get("columns") or auto_detect_columns(df.columns)
    true_vals = set(cfg.get("defaults", {}).get("true_values", ["1", "true", "yes", "in stock"]))
    store_raw = cfg.get("defaults", {}).get("store_raw", True)

    out = prepare(df, colmap, true_vals, dt.datetime.now(dt.timezone.utc), store_raw)
    if out.empty:
        return 0
    out["platform"] = platform
    _ensure_partitions(conn, out["observed_at"])
    with conn.cursor() as cur:
        cur.execute(_STG)
        with cur.copy("copy stg (" + ",".join(COLS) + ") from stdin (format csv, null '\\N')") as cp:
            cp.write(out[COLS].to_csv(index=False, header=False, na_rep="\\N"))
        for sql in _STEPS:
            cur.execute(sql)
    conn.commit()
    return len(out)


def start_batch(conn, platform, kind, source):
    with conn.cursor() as cur:
        cur.execute("insert into sidnl.ingest_batches (platform, kind, source_file) values (%s,%s,%s) returning batch_id",
                    (platform, kind, str(source)))
        bid = cur.fetchone()[0]
    conn.commit()
    return bid


def finish_batch(conn, batch_id, rows):
    with conn.cursor() as cur:
        cur.execute("update sidnl.ingest_batches set rows_in=%s, finished_at=now() where batch_id=%s", (rows, batch_id))
    conn.commit()


def load_records(conn, platform, records, kind="live", source="stream"):
    """Real-time entry point: a list of dicts (already parsed JSON)."""
    bid = start_batch(conn, platform, kind, source)
    n = load_df(conn, platform, pd.DataFrame.from_records(records))
    finish_batch(conn, bid, n)
    return n
