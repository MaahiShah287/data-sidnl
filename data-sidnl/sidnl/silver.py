"""Silver helpers. The pipeline itself runs inside Supabase (pg_cron -> silver.run_tick); this is only for checking it.

Bronze (public.*) -> silver (metric tables only) -> gold. Run history and data-quality results live in schema ops.
"""
import json

DEFAULT_BRAND = "mr munchies"


def selftest(conn):
    with conn.cursor() as cur:
        cur.execute("select silver.selftest_parser()")
        msg = cur.fetchone()[0]
    print(msg)
    return msg


def run(conn, force=False):
    """Run the whole bronze -> silver pipeline now (what cron does every minute). Idempotent."""
    with conn.cursor() as cur:
        cur.execute("select silver.run_pipeline(%s, 'manual')", (force,))
        res = cur.fetchone()[0]
    conn.commit()
    print(json.dumps({k: res.get(k) for k in ("status", "mode", "run_id", "gold_status")}, indent=2, default=str))
    return res


def refresh(conn, brand=DEFAULT_BRAND):
    """Idempotent bronze -> silver load for one brand."""
    with conn.cursor() as cur:
        cur.execute("select silver.refresh_brand(%s)", (brand,))
        stats = cur.fetchone()[0]
    conn.commit()
    print(json.dumps(stats, indent=2, default=str))
    return stats


def report(conn):
    """Pipeline health, data quality and listing %."""
    with conn.cursor() as cur:
        cur.execute("select * from ops.v_silver_health")
        cols = [c.name for c in cur.description]
        print("-- health")
        for k, v in zip(cols, cur.fetchone()): print(f"{k:32s} {v}")
        cur.execute("select dq_status, dq_flag, sum(readings) from ops.v_dq_summary group by 1,2 order by 1,3 desc")
        print("-- data quality")
        for r in cur.fetchall(): print(*r, sep=" | ")
        cur.execute("""select product_name, listing_stores, eligible_stores, listing_pct, eligible_stores_stopped_early
                       from silver.v_sku_listing where city_slug = 'ALL' order by listing_pct desc""")
        print("-- listing % (ALL cities; floor when scans stopped early)")
        for r in cur.fetchall(): print(*r, sep=" | ")
