"""
scripts/load_first_party.py
Loads first-party (seller-portal) Excel exports into bronze public.fp_blinkit_ads.

Usage:
    python scripts/load_first_party.py [file1 file2 ...]
    (no args = load every supported file in first_party/)

Requires SUPABASE_DB_URL in the environment (admin session-pooler URL, like
tests/test_live_db.py). The read-only chatbot role CANNOT load files.

Idempotent:
  - each file is identified by its sha256 in public.fp_load_file: a file is
    loaded at most once;
  - rows are deduped by the fp_blinkit_ads_uq unique index (ON CONFLICT DO
    NOTHING), so overlapping files (e.g. the keyword sheet and the
    PRODUCT_LISTING sheet of the same month) cannot double-count.
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent          # data-sidnl/ (inner)
FIRST_PARTY_DIR = PROJECT_ROOT.parent / "first_party"           # repo root/first_party
NA_VALUES = {"#-NA", "-", "", "NA", "N/A"}

try:
    import psycopg
except ImportError:
    try:
        import psycopg2 as psycopg  # type: ignore
    except ImportError:
        print("ERROR: pip install psycopg[binary] (or psycopg2-binary)")
        sys.exit(1)

import pandas as pd


def clean(v):
    """Portal exports use '#-NA' and blanks; convert to None."""
    if isinstance(v, str) and v.strip() in NA_VALUES:
        return None
    if pd.isna(v):
        return None
    if isinstance(v, (datetime, date)):
        return v if isinstance(v, date) else v.date()
    if isinstance(v, Decimal):
        return v
    if isinstance(v, str):
        return v.strip()
    return v


def num(v):
    v = clean(v)
    if v is None:
        return None
    return float(str(v).replace(",", "").replace("%", "").strip())


def dnum(v):
    v = clean(v)
    if v is None:
        return None
    # both '01-10-2026' (dd-mm) and '2026-10-01' appear across portals
    for fmt in ("%Y-%m-%d", "%d-%m-%Y", "%d/%m/%Y", "%m/%d/%Y"):
        try:
            return datetime.strptime(str(v).strip()[:10], fmt).date()
        except ValueError:
            continue
    if isinstance(v, (datetime, date)):
        return v.date() if isinstance(v, datetime) else v
    raise ValueError(f"unparseable date: {v!r}")


def parse_search_report(path: Path) -> list[dict]:
    """791_Search_Reports_*.xlsx — Blinkit ads portal (keyword + reco + MTD)."""
    rows: list[dict] = []
    xl = pd.ExcelFile(path)

    df = pd.read_excel(xl, "Keyword Targeting")
    for _, r in df.iterrows():
        rows.append(dict(
            report_type="keyword_daily", obs_date=dnum(r["date_ist"]),
            campaign_id=str(r["Campaign ID"]), campaign_name=clean(r["Campaign Name"]),
            ad_type="Product Booster", target_type="Keyword", target_value=clean(r["Keyword"]),
            match_type=clean(r["Match Type"]), pacing_type=clean(r["Pacing Type"]),
            most_viewed_position=clean(r["Most Viewed Position"]),
            cpm=num(r["CPM"]), total_budget=num(r["Total Budget"]),
            impressions=num(r["Impressions"]), direct_atc=num(r["Direct ATC"]),
            indirect_atc=num(r["Indirect ATC"]), new_users=num(r["New Users"]),
            direct_sales=num(r["Direct Sales"]), indirect_sales=num(r["Indirect Sales"]),
            direct_qty=num(r["Direct Quantities Sold"]),
            indirect_qty=num(r["Indirect Quantities Sold"]),
            budget_consumed=num(r["Estimated Budget Consumed"]),
            direct_roas=num(r["Direct RoAS"]), total_roas=num(r["Total RoAS"]),
        ))

    df = pd.read_excel(xl, "Product Recommendation")
    for _, r in df.iterrows():
        rows.append(dict(
            report_type="reco_daily", obs_date=dnum(r["date_ist"]),
            campaign_id=str(r["Campaign ID"]), campaign_name=clean(r["Campaign Name"]),
            subcampaign_id=str(clean(r["Subcampaign ID"]) or ""),
            ad_type="Recommendation Ads",
            target_type="Asset", target_value=clean(r["Asset"]) or clean(r["Title"]),
            pacing_type=clean(r["Pacing Type"]),
            cpm=num(r["CPM"]), total_budget=num(r["Total Budget"]),
            impressions=num(r["Impressions"]), direct_atc=num(r["Direct ATC"]),
            indirect_atc=num(r["Indirect ATC"]), new_users=num(r["New Users"]),
            direct_sales=num(r["Direct Sales"]), indirect_sales=num(r["Indirect Sales"]),
            direct_qty=num(r["Direct Quantities Sold"]),
            indirect_qty=num(r["Indirect Quantities Sold"]),
            budget_consumed=num(r["Estimated Budget Consumed"]),
            direct_roas=num(r["Direct RoAS"]), total_roas=num(r["Total RoAS"]),
        ))

    df = pd.read_excel(xl, "MTD Claimables")
    for _, r in df.iterrows():
        rows.append(dict(
            report_type="mtd_claimables",
            campaign_id=str(r["Campaign ID"]), campaign_name=clean(r["Campaign Name"]),
            ad_type=clean(r["Campaign Type"]),
            impressions=num(r["Impressions"]), total_budget=num(r["Total Budget"]),
            claimables=num(r["Claimables"]),
            served_budget=num(r["served_budget_consumed"]),
        ))
    return rows


def parse_sov_report(path: Path) -> list[dict]:
    """sponsored_sov_*.xls — Blinkit Sponsored SoV summary."""
    rows: list[dict] = []
    df = pd.read_excel(path, "Sponsored SoV")
    for _, r in df.iterrows():
        rows.append(dict(
            report_type="sov_period",
            period_start=dnum(r["Start Date"]), period_end=dnum(r["End Date"]),
            campaign_id="sov", target_type="Keyword", target_value=clean(r["Keyword"]),
            searches=num(r["Searches"]), sov_pct=num(r["Share of Voice (%)"]),
        ))
    return rows


def parse_monthly_report(path: Path) -> list[dict]:
    """Report_<date>_to_<date>.xls — Blinkit ads portal, product-level export."""
    rows: list[dict] = []
    xl = pd.ExcelFile(path)

    df = pd.read_excel(xl, "PRODUCT_LISTING")
    for _, r in df.iterrows():
        rows.append(dict(
            report_type="keyword_daily", obs_date=dnum(r["Date"]),
            campaign_id=str(r["Campaign ID"]), campaign_name=clean(r["Campaign Name"]),
            ad_type="Product Booster",
            target_type=clean(r["Targeting Type"]) or "Keyword",
            target_value=clean(r["Targeting Value"]),
            match_type=clean(r["Match Type"]),
            most_viewed_position=clean(r["Most Viewed Position"]),
            pacing_type=clean(r["Pacing Type"]),
            cpm=num(r["CPM"]),
            impressions=num(r["Impressions"]), direct_atc=num(r["Direct ATC"]),
            indirect_atc=num(r["Indirect ATC"]),
            new_users=num(r["New Users Acquired"]),
            direct_sales=num(r["Direct Sales"]), indirect_sales=num(r["Indirect Sales"]),
            direct_qty=num(r["Direct Quantities Sold"]),
            indirect_qty=num(r["Indirect Quantities Sold"]),
            budget_consumed=num(r["Estimated Budget Consumed"]),
            direct_roas=num(r["Direct RoAS"]), total_roas=num(r["Total RoAS"]),
        ))

    df = pd.read_excel(xl, "PRODUCT_RECOMMENDATION")
    for _, r in df.iterrows():
        rows.append(dict(
            report_type="reco_daily", obs_date=dnum(r["Date"]),
            campaign_id=str(r["Campaign ID"]), campaign_name=clean(r["Campaign Name"]),
            ad_type="Recommendation Ads",
            target_type=clean(r["Targeting Type"]),
            target_value=clean(r["Targeting Type"]),
            pacing_type=clean(r["Pacing Type"]),
            cpm=num(r["CPM"]),
            impressions=num(r["Impressions"]), direct_atc=num(r["Direct ATC"]),
            indirect_atc=num(r["Indirect ATC"]),
            new_users=num(r["New Users Acquired"]),
            direct_sales=num(r["Direct Sales"]), indirect_sales=num(r["Indirect Sales"]),
            direct_qty=num(r["Direct Quantities Sold"]),
            indirect_qty=num(r["Indirect Quantities Sold"]),
            budget_consumed=num(r["Estimated Budget Consumed"]),
            direct_roas=num(r["Direct RoAS"]), total_roas=num(r["Total RoAS"]),
        ))
    return rows


PARSERS = [
    ("791_Search_Reports", parse_search_report),
    ("sponsored_sov", parse_sov_report),
    ("Report_", parse_monthly_report),
]


def parse_file(path: Path) -> list[dict]:
    for prefix, parser in PARSERS:
        if path.name.startswith(prefix):
            return parser(path)
    raise ValueError(f"no parser for {path.name} — add one to PARSERS")


def load_env_file() -> None:
    """Read KEY=VALUE pairs from repo-root .env (if present) into os.environ.
    Existing environment variables win. .env is git-ignored and never printed."""
    env_path = PROJECT_ROOT.parent / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key, value = key.strip(), value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


load_env_file()


def main():
    args = sys.argv[1:]
    files = [Path(a) for a in args] if args else \
        sorted(p for p in FIRST_PARTY_DIR.glob("*") if p.is_file())
    if not files:
        print("No files to load. Put Excel exports in first_party/ or pass paths.")
        sys.exit(1)

    dsn = os.environ.get("SUPABASE_DB_URL", "")
    if not dsn:
        print("ERROR: SUPABASE_DB_URL not set.\n"
              "Create .env in the repo root (copy .env.example) or set the\n"
              "SUPABASE_DB_URL environment variable. Never commit .env.")
        sys.exit(1)

    with psycopg.connect(dsn, connect_timeout=15) as conn:
        for path in files:
            sha = hashlib.sha256(path.read_bytes()).hexdigest()
            dup = conn.execute(
                "select 1 from public.fp_load_file where file_sha256=%s", (sha,)
            ).fetchone()
            if dup:
                print(f"[skip] {path.name} already loaded (sha256 known)")
                continue

            try:
                rows = parse_file(path)
            except Exception as exc:
                print(f"[error] {path.name}: {exc}")
                continue

            cols = ["report_type","obs_date","period_start","period_end","campaign_id",
                    "campaign_name","subcampaign_id","ad_type","target_type","target_value",
                    "match_type","pacing_type","most_viewed_position","cpm","total_budget",
                    "impressions","direct_atc","indirect_atc","new_users","direct_sales",
                    "indirect_sales","direct_qty","indirect_qty","budget_consumed",
                    "direct_roas","total_roas","searches","sov_pct","claimables",
                    "served_budget"]
            insert_count = 0
            for r in rows:
                r["raw"] = json.dumps({k: (str(v) if isinstance(v, (date, datetime, Decimal)) else v)
                                       for k, v in r.items() if v is not None})
                r["source_file"] = path.name
                placeholders = ",".join(["%s"] * len(cols))
                cur = conn.execute(
                    f"insert into public.fp_blinkit_ads({','.join(cols)},raw,source_file) "
                    f"values ({placeholders},%s,%s) on conflict do nothing",
                    [clean(r.get(c)) for c in cols] + [r["raw"], r["source_file"]])
                insert_count += cur.rowcount

            conn.execute(
                "insert into public.fp_load_file(file_sha256,file_name,row_count) "
                "values (%s,%s,%s) on conflict (file_sha256) do nothing",
                (sha, path.name, len(rows)))
            conn.commit()
            print(f"[ok]   {path.name}: {len(rows)} rows parsed, {insert_count} new in bronze")

        print("\nNow run in Supabase SQL editor (or the sidnl-ads-refresh cron does it):")
        print("  select silver.load_fp_ads();")
        print("  select dash.refresh_ads();")


if __name__ == "__main__":
    main()
