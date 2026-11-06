"""
scripts/profile_data.py
========================
Stage A: connects to Supabase (read-only), queries the three allowlisted views,
and writes reports/data_profile.md.

Usage:
    python scripts/profile_data.py

Requires DATABASE_URL in .env (sidnl_chatbot_ro credentials).
No writes. Never reads silver.demo.
"""
from __future__ import annotations

import os
import sys
import json
import textwrap
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Bootstrap: load .env from project root
# ---------------------------------------------------------------------------
PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "src"))

try:
    from dotenv import load_dotenv
    load_dotenv(PROJECT_ROOT / ".env")
except ImportError:
    pass  # dotenv optional; env vars may already be set

DATABASE_URL = os.environ.get("DATABASE_URL", "")
if not DATABASE_URL:
    print("ERROR: DATABASE_URL not set. Copy .env.example to .env and fill in the value.")
    sys.exit(1)

try:
    import psycopg
except ImportError:
    print("ERROR: psycopg not installed. Run: pip install psycopg[binary]")
    sys.exit(1)

REPORTS_DIR = PROJECT_ROOT / "reports"
REPORTS_DIR.mkdir(exist_ok=True)
OUTPUT_FILE = REPORTS_DIR / "data_profile.md"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def q(conn, sql: str, params: tuple = ()) -> list[dict[str, Any]]:
    """Execute a read-only query and return rows as list of dicts."""
    with conn.cursor() as cur:
        cur.execute(sql, params)
        cols = [d.name for d in cur.description]
        return [dict(zip(cols, row)) for row in cur.fetchall()]


def pct(num: int, denom: int) -> str:
    if denom == 0:
        return "N/A"
    return f"{num / denom * 100:.1f}%"


def md_table(headers: list[str], rows: list[list[Any]]) -> str:
    sep = "|".join(["---"] * len(headers))
    lines = ["| " + " | ".join(str(h) for h in headers) + " |",
             "| " + sep + " |"]
    for row in rows:
        lines.append("| " + " | ".join(str(c) for c in row) + " |")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Platform tables (base tables — queried directly for raw counts only)
# HARD RULE: silver.demo is excluded from every query.
# ---------------------------------------------------------------------------
PLATFORMS = ["blinkit", "zepto", "instamart", "jiomart"]
VIEWS = {
    "v_all_platforms":          "silver.v_all_platforms",
    "v_latest_observation":     "silver.v_latest_observation",
    "v_latest_shelf_position":  "silver.v_latest_shelf_position",
}

# ---------------------------------------------------------------------------
# Main profiling logic
# ---------------------------------------------------------------------------

def run_profile(conn) -> dict[str, Any]:
    data: dict[str, Any] = {}

    # ---- 1. Row counts ----
    data["raw_counts"] = {}
    for p in PLATFORMS:
        rows = q(conn, f"SELECT source_type, COUNT(*) AS n FROM silver.{p} GROUP BY source_type ORDER BY source_type")
        data["raw_counts"][p] = rows

    data["view_counts"] = {}
    for vname, vtable in VIEWS.items():
        rows = q(conn, f"SELECT platform, COUNT(*) AS n FROM {vtable} GROUP BY platform ORDER BY platform")
        data["view_counts"][vname] = rows

    # ---- 2. Distinct values ----
    cat_cols = ["scrape_status", "scrape_run_status", "data_quality_status",
                "stock_status", "inventory_status", "ad_type", "product_type"]
    data["distinct_values"] = {}
    for col in cat_cols:
        union = " UNION ALL ".join(
            f"SELECT platform, {col} AS val FROM silver.{p}" for p in PLATFORMS
        )
        rows = q(conn, f"""
            SELECT platform, val, COUNT(*) AS n
            FROM ({union}) t
            GROUP BY platform, val
            ORDER BY platform, n DESC
        """)
        data["distinct_values"][col] = rows

    # ---- 3. NULL % per platform ----
    null_cols = ["listing_id", "store_id", "availability", "sale_price",
                 "mrp", "discount_percentage", "position", "organic_position",
                 "is_ad", "brand", "city"]
    null_selects = ", ".join(
        f"ROUND(SUM(CASE WHEN {c} IS NULL THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) AS null_{c}"
        for c in null_cols
    )
    union_all = " UNION ALL ".join(
        f"SELECT platform, source_type, {', '.join(null_cols)} FROM silver.{p}"
        for p in PLATFORMS
    )
    data["null_pct"] = q(conn, f"""
        SELECT platform, source_type, COUNT(*) AS total, {null_selects}
        FROM ({union_all}) t
        GROUP BY platform, source_type
        ORDER BY platform, source_type
    """)

    # ---- 4. Temporal coverage ----
    union_all_time = " UNION ALL ".join(
        f"SELECT platform, source_type, observed_at FROM silver.{p}" for p in PLATFORMS
    )
    data["temporal"] = q(conn, f"""
        SELECT platform, source_type,
            MIN(observed_at) AS earliest, MAX(observed_at) AS latest,
            COUNT(*) AS total_rows
        FROM ({union_all_time}) t
        GROUP BY platform, source_type ORDER BY platform, source_type
    """)

    # Distinct cities, stores, brands, L1/L2 per platform
    union_all_dim = " UNION ALL ".join(
        f"SELECT platform, city, store_id, brand, l1_category, l2_category FROM silver.{p}"
        for p in PLATFORMS
    )
    data["dimensions"] = q(conn, f"""
        SELECT platform,
            COUNT(DISTINCT city)        AS distinct_cities,
            COUNT(DISTINCT store_id)    AS distinct_stores,
            COUNT(DISTINCT brand)       AS distinct_brands,
            COUNT(DISTINCT l1_category) AS distinct_l1,
            COUNT(DISTINCT l2_category) AS distinct_l2
        FROM ({union_all_dim}) t
        GROUP BY platform ORDER BY platform
    """)

    # ---- 5. Cross source-type overlap ----
    union_all_src = " UNION ALL ".join(
        f"SELECT platform, COALESCE(listing_id, platform_product_id) AS eid, store_id, source_type FROM silver.{p}"
        for p in PLATFORMS
    )
    data["overlap"] = q(conn, f"""
        WITH base AS ({union_all_src}),
        piv AS (
            SELECT platform, eid, store_id,
                BOOL_OR(source_type = 'observation') AS has_obs,
                BOOL_OR(source_type = 'shelf_position') AS has_shelf
            FROM base GROUP BY platform, eid, store_id
        )
        SELECT platform,
            COUNT(*) FILTER (WHERE has_obs AND has_shelf) AS overlap_count,
            COUNT(*) FILTER (WHERE has_obs AND NOT has_shelf) AS obs_only,
            COUNT(*) FILTER (WHERE NOT has_obs AND has_shelf) AS shelf_only
        FROM piv GROUP BY platform ORDER BY platform
    """)

    # ---- 6. Duplicate source_record_id ----
    union_all_dup = " UNION ALL ".join(
        f"SELECT platform, source_type, source_record_id FROM silver.{p}" for p in PLATFORMS
    )
    data["duplicates_summary"] = q(conn, f"""
        SELECT platform, source_type,
            COUNT(*) AS distinct_dup_source_record_ids,
            SUM(dup_count - 1) AS excess_rows
        FROM (
            SELECT platform, source_type, source_record_id, COUNT(*) AS dup_count
            FROM ({union_all_dup}) t
            WHERE source_record_id IS NOT NULL
            GROUP BY platform, source_type, source_record_id HAVING COUNT(*) > 1
        ) d
        GROUP BY platform, source_type ORDER BY platform, source_type
    """)

    # ---- 7. Sanity flags ----
    union_all_sanity = " UNION ALL ".join(
        f"SELECT platform, source_type, sale_price, mrp, discount_percentage, availability FROM silver.{p}"
        for p in PLATFORMS
    )
    data["sanity"] = q(conn, f"""
        SELECT platform, source_type,
            COUNT(*) AS total,
            SUM(CASE WHEN sale_price > mrp AND mrp > 0 THEN 1 ELSE 0 END) AS sale_gt_mrp,
            SUM(CASE WHEN sale_price < 0 OR mrp < 0 THEN 1 ELSE 0 END) AS negative_prices,
            SUM(CASE WHEN discount_percentage < 0 OR discount_percentage > 100 THEN 1 ELSE 0 END) AS bad_discount_pct,
            ROUND(SUM(CASE WHEN availability IS NULL THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(*), 0), 1) AS null_avail_pct
        FROM ({union_all_sanity}) t
        GROUP BY platform, source_type ORDER BY platform, source_type
    """)

    return data


def build_recommended_filters(data: dict) -> str:
    """
    Examine scrape_status and scrape_run_status distributions and suggest
    which values to keep.  We flag any value that accounts for >=5% of rows.
    """
    lines = []
    for col in ["scrape_status", "scrape_run_status"]:
        platform_vals: dict[str, list] = {}
        for row in data["distinct_values"].get(col, []):
            platform_vals.setdefault(row["platform"], []).append(row)

        lines.append(f"\n### {col}")
        for plat, prows in sorted(platform_vals.items()):
            total = sum(r["n"] for r in prows)
            dominant = [r for r in prows if r["n"] / total >= 0.05]
            vals = [f"'{r['val']}' ({r['n']:,} rows, {r['n']/total*100:.1f}%)"
                    for r in dominant if r["val"] is not None]
            null_rows = [r for r in prows if r["val"] is None]
            null_note = f"; {null_rows[0]['n']:,} NULL rows" if null_rows else ""
            lines.append(f"- **{plat}**: dominant values → {', '.join(vals) or '(all null)'}{null_note}")

    lines.append("""
> **Action**: Replace the `TODO(diagnostics)` stubs in `sql/01_views.sql` with:
> ```sql
> AND scrape_status IN (<dominant non-null scrape_status values above>)
> AND scrape_run_status IN (<dominant non-null scrape_run_status values above>)
> ```
> Review NULL rows separately — a NULL scrape_status may indicate a scraper bug rather than a valid record.
""")
    return "\n".join(lines)


def render_report(data: dict) -> str:
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    sections: list[str] = []

    sections.append(f"# SIDNL Data Profile Report\n\n_Generated: {now}_\n\n"
                    "> **Hard rule**: silver.demo is excluded from every query in this report.")

    # --- 1. Row counts ---
    sections.append("## 1. Row Counts")
    sections.append("### 1a. Raw base-table counts (per platform, per source_type)")
    hdr = ["platform", "source_type", "raw_rows"]
    rows_out = []
    for p in PLATFORMS:
        for r in data["raw_counts"][p]:
            rows_out.append([p, r["source_type"] or "NULL", f"{r['n']:,}"])
    sections.append(md_table(hdr, rows_out))

    sections.append("\n### 1b. View counts (deduplicated / filtered)")
    for vname, vrows in data["view_counts"].items():
        sections.append(f"\n**{vname}**")
        if vrows:
            sections.append(md_table(["platform", "rows"],
                                     [[r["platform"], f"{r['n']:,}"] for r in vrows]))
        else:
            sections.append("_No rows returned (view may be empty or views not yet applied to DB)._")

    # --- 2. Distinct values ---
    sections.append("\n## 2. Distinct Values for Key Categorical Columns")
    cat_cols = ["scrape_status", "scrape_run_status", "data_quality_status",
                "stock_status", "inventory_status", "ad_type", "product_type"]
    for col in cat_cols:
        sections.append(f"\n### {col}")
        col_rows = data["distinct_values"].get(col, [])
        if col_rows:
            sections.append(md_table(["platform", "value", "count"],
                                     [[r["platform"], repr(r["val"]), f"{r['n']:,}"]
                                      for r in col_rows]))
        else:
            sections.append("_No data._")

    # --- 3. NULL % ---
    sections.append("\n## 3. NULL % Per Platform")
    null_cols = ["listing_id", "store_id", "availability", "sale_price",
                 "mrp", "discount_percentage", "position", "organic_position",
                 "is_ad", "brand", "city"]
    hdr3 = ["platform", "source_type", "total"] + [f"null_{c}%" for c in null_cols]
    rows3 = []
    for r in data["null_pct"]:
        row = [r["platform"], r["source_type"] or "NULL", f"{r['total']:,}"]
        for c in null_cols:
            row.append(str(r.get(f"null_{c}", "N/A")))
        rows3.append(row)
    sections.append(md_table(hdr3, rows3))

    # --- 4. Temporal ---
    sections.append("\n## 4. Temporal Coverage and Dimension Counts")
    sections.append("\n### 4a. observed_at range")
    sections.append(md_table(
        ["platform", "source_type", "earliest", "latest", "total_rows"],
        [[r["platform"], r["source_type"] or "NULL",
          str(r["earliest"]), str(r["latest"]), f"{r['total_rows']:,}"]
         for r in data["temporal"]]))

    sections.append("\n### 4b. Distinct cities, stores, brands, L1/L2")
    sections.append(md_table(
        ["platform", "cities", "stores", "brands", "L1 categories", "L2 categories"],
        [[r["platform"], r["distinct_cities"], r["distinct_stores"],
          r["distinct_brands"], r["distinct_l1"], r["distinct_l2"]]
         for r in data["dimensions"]]))

    # --- 5. Cross source-type overlap ---
    sections.append("\n## 5. Cross Source-Type Overlap")
    sections.append("> Non-zero `overlap_count` means the same (platform, listing_id, store_id) "
                    "has BOTH observation and shelf_position rows. The hard rule says these must "
                    "not be mixed silently.")
    sections.append(md_table(
        ["platform", "overlap_count", "obs_only", "shelf_only"],
        [[r["platform"], f"{r['overlap_count']:,}", f"{r['obs_only']:,}", f"{r['shelf_only']:,}"]
         for r in data["overlap"]]))

    # --- 6. Duplicates ---
    sections.append("\n## 6. Duplicate source_record_id")
    if data["duplicates_summary"]:
        sections.append(md_table(
            ["platform", "source_type", "distinct_dup_ids", "excess_rows"],
            [[r["platform"], r["source_type"],
              f"{r['distinct_dup_source_record_ids']:,}",
              f"{r['excess_rows']:,}"]
             for r in data["duplicates_summary"]]))
    else:
        sections.append("✅ No duplicates on (platform, source_type, source_record_id).")

    # --- 7. Sanity flags ---
    sections.append("\n## 7. Sanity Flags")
    sections.append("> `null_avail_pct > 20` triggers a data-quality warning.")
    hdr7 = ["platform", "source_type", "total", "sale>mrp", "neg_prices", "bad_disc%", "null_avail%"]
    rows7 = []
    for r in data["sanity"]:
        warn = " ⚠️" if (r.get("null_avail_pct") or 0) > 20 else ""
        rows7.append([r["platform"], r["source_type"] or "NULL", f"{r['total']:,}",
                      f"{r['sale_gt_mrp']:,}", f"{r['negative_prices']:,}",
                      f"{r['bad_discount_pct']:,}", f"{r['null_avail_pct']}{warn}"])
    sections.append(md_table(hdr7, rows7))

    # --- 8. Recommended filters ---
    sections.append("\n## 8. Recommended View Filters")
    sections.append(build_recommended_filters(data))

    return "\n\n".join(sections)


def main():
    print(f"Connecting to database (read-only)…")
    try:
        with psycopg.connect(DATABASE_URL, options="-c default_transaction_read_only=on") as conn:
            print("Connected. Running profiling queries…")
            data = run_profile(conn)
    except Exception as exc:
        print(f"ERROR connecting or querying: {exc}")
        sys.exit(1)

    print("Rendering report…")
    report = render_report(data)
    OUTPUT_FILE.write_text(report, encoding="utf-8")
    print(f"✅ Report written to: {OUTPUT_FILE}")


if __name__ == "__main__":
    main()
