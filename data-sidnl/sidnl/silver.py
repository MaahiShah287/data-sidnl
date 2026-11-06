"""Silver layer runner: apply SQL, refresh a brand from bronze, report freshness / DQ, run parser self-test.

Bronze (public.*)  ->  silver (star schema, brand-scoped)  ->  gold (sql/gold/*, reads silver.<platform> views)
All SQL lives in sql/silver/*.sql (numbered, idempotent). Business logic is in Postgres functions
(silver.parse_pack, silver.reading_dq, silver.refresh_brand ...) so every consumer gets identical parsing.
"""
import json
from .common import ROOT

SILVER_DIR = ROOT / "sql" / "silver"
DEFAULT_BRAND = "mr munchies"


def apply(conn):
    """Apply sql/silver/NNN_*.sql in order. Safe to re-run (all files are idempotent)."""
    done = []
    for f in sorted(SILVER_DIR.glob("[0-9][0-9][0-9]_*.sql")):
        with conn.cursor() as cur:
            cur.execute(f.read_text(encoding="utf-8"))
        conn.commit()
        done.append(f.name)
        print("applied", f.name)
    return done


def selftest(conn):
    with conn.cursor() as cur:
        cur.execute("select silver.selftest_parser()")
        msg = cur.fetchone()[0]
    print(msg)
    return msg


def refresh(conn, brand=DEFAULT_BRAND):
    """Idempotent bronze -> silver load for one brand. Returns the stats dict the SQL function logs to silver.etl_run."""
    with conn.cursor() as cur:
        cur.execute("select silver.refresh_brand(%s)", (brand,))
        stats = cur.fetchone()[0]
    conn.commit()
    print(json.dumps(stats, indent=2, default=str))
    return stats


def report(conn):
    """Print freshness per source, DQ flags and listing %."""
    with conn.cursor() as cur:
        cur.execute("""select platform, brand_key, source_type, readings, fresh_readings, stale_readings,
                              hours_since_last_reading, source_status
                       from silver.v_data_freshness order by 1,2,3""")
        print("-- freshness (platform, brand, source, readings, fresh, stale, hours since last, status)")
        for r in cur.fetchall(): print(*r, sep=" | ")
        cur.execute("""select dq_status, dq_flag, sum(readings) from silver.v_dq_summary
                       group by 1,2 order by 1,3 desc""")
        print("-- data quality")
        for r in cur.fetchall(): print(*r, sep=" | ")
        cur.execute("""select product_name, listing_stores, eligible_stores, listing_pct, eligible_stores_stopped_early
                       from silver.v_sku_listing where city_slug = 'ALL' order by listing_pct desc""")
        print("-- listing % (ALL cities; floor when scans stopped early)")
        for r in cur.fetchall(): print(*r, sep=" | ")
