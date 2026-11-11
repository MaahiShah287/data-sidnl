"""
scripts/run_ground_truth.py
Runs each NUMERIC question's ground_truth_sql against the silver views
and fills ground_truth_value + ground_truth_rows_sample in eval/questions.jsonl.

Usage:
    python scripts/run_ground_truth.py

Requires DATABASE_URL in .env. Never reads silver.demo.
"""
from __future__ import annotations
import os, sys, json
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "src"))

try:
    from dotenv import load_dotenv
    load_dotenv(PROJECT_ROOT / ".env")
except ImportError:
    pass

DATABASE_URL = os.environ.get("DATABASE_URL", "")
if not DATABASE_URL:
    print("ERROR: DATABASE_URL not set.")
    sys.exit(1)

try:
    import psycopg2 as psycopg
except ImportError:
    try:
        import psycopg
    except ImportError:
        print("ERROR: pip install psycopg2-binary")
        sys.exit(1)

import re

QUESTIONS_FILE = PROJECT_ROOT / "eval" / "questions.jsonl"
GT_RESULTS_FILE = PROJECT_ROOT / "reports" / "ground_truth_results.md"
(PROJECT_ROOT / "reports").mkdir(exist_ok=True)

BLOCKED = ["silver.demo"]


def run_sql(conn, sql: str, limit: int = 5):
    sql_lower = sql.lower()
    for b in BLOCKED:
        if b in sql_lower:
            return None, f"BLOCKED: SQL references {b}"
    # Add LIMIT only if not already present
    sql_to_run = sql if re.search(r'\blimit\b', sql, re.IGNORECASE) else sql + f"\nLIMIT {limit}"
    try:
        with conn.cursor() as cur:
            cur.execute(sql_to_run)
            cols = [d[0] for d in cur.description]
            rows = [dict(zip(cols, row)) for row in cur.fetchall()]
        return rows, None
    except Exception as exc:
        return None, str(exc)


def to_serializable(obj):
    """Make values JSON-safe."""
    import decimal, datetime
    if isinstance(obj, (decimal.Decimal,)):
        return float(obj)
    if isinstance(obj, (datetime.datetime, datetime.date)):
        return obj.isoformat()
    return str(obj)


def clean_rows(rows):
    if not rows:
        return rows
    return [{k: to_serializable(v) for k, v in r.items()} for r in rows]


def extract_primary_value(rows, primary_column: str | None = None):
    if not rows:
        return None
    first = rows[0]
    # An explicit column beats every heuristic below: the heuristic used to
    # return `listing_count` instead of the metric (e.g. 489 stores -> 489
    # listings), which silently corrupted the ground-truth value.
    if primary_column and primary_column in first and first[primary_column] is not None:
        return str(first[primary_column])
    priority = ["in_stock_pct", "oos_rate_pct", "avg_disc", "avg_sale_price",
                "avg_position", "avg_organic_pos", "ad_pct", "avg_eta_minutes",
                "in_stock_rate_pct", "avg_discount_pct", "sale_price", "mrp",
                "distinct_brands", "sku_count", "row_count", "n",
                "listing_count", "avg_disc", "in_stock", "total"]
    for col in priority:
        if col in first and first[col] is not None:
            return str(first[col])
    for col, val in first.items():
        if val is None:
            continue
        try:
            float(val)
            return str(val)
        except (TypeError, ValueError):
            pass
    # Return first non-null value
    for col, val in first.items():
        if val is not None:
            return str(val)
    return None


def parse_dsn(url):
    """
    Split a postgres DSN without breaking on passwords that contain '@' or ':'.

    urlsplit() splits the userinfo at the LAST '@' and the password at the
    FIRST ':', so raw (unencoded) special characters are handled correctly.
    """
    from urllib.parse import urlsplit, unquote

    try:
        parts = urlsplit(url)
        port = parts.port
    except ValueError:
        return None
    if not parts.hostname or not parts.path or parts.path == "/":
        return None
    return dict(
        host=parts.hostname,
        port=port or 5432,
        dbname=unquote(parts.path.lstrip("/")),
        user=unquote(parts.username or ""),
        password=unquote(parts.password or ""),
        sslmode="require",
    )


def main():
    print("Connecting (read-only)...")
    dsn = parse_dsn(DATABASE_URL)
    if dsn:
        conn = psycopg.connect(**dsn, connect_timeout=15)
    else:
        conn = psycopg.connect(DATABASE_URL, connect_timeout=15)
    print("Connected.")

    questions = [json.loads(l) for l in
                 QUESTIONS_FILE.read_text(encoding="utf-8").splitlines() if l.strip()]
    numeric_qs = [q for q in questions
                  if q.get("expected_route") == "NUMERIC" and q.get("ground_truth_sql")]

    print(f"Running ground truth for {len(numeric_qs)} NUMERIC questions...\n")

    results = []
    md_lines = [
        "# Ground Truth Results\n",
        f"_Run against views only. silver.demo excluded._\n",
        "| ID | Question | Rows | Primary Value | Error |",
        "|---|---|---|---|---|",
    ]

    for q in numeric_qs:
        qid = q["id"]
        sql = q["ground_truth_sql"]
        print(f"  {qid}...", end=" ", flush=True)
        rows, err = run_sql(conn, sql, limit=10)
        rows = clean_rows(rows) if rows else rows
        primary = extract_primary_value(rows, q.get("primary_column")) if rows else None
        status = "OK" if rows is not None else "ERR"
        print(f"[{status}] {len(rows) if rows else 0} rows  primary={primary}")
        if err:
            print(f"       ERROR: {err}")
        results.append({"id": qid, "rows": rows, "primary_value": primary, "error": err})
        q_short = q["question"][:60].replace("|", "/")
        md_lines.append(
            f"| {qid} | {q_short} | {len(rows) if rows else 0} | {primary or 'N/A'} | {err or ''} |"
        )

    conn.close()

    # Write updated questions.jsonl
    result_map = {r["id"]: r for r in results}
    updated = []
    for q in questions:
        if q["id"] in result_map:
            q["ground_truth_value"] = result_map[q["id"]]["primary_value"]
            q["ground_truth_rows_sample"] = result_map[q["id"]]["rows"]
        updated.append(q)

    QUESTIONS_FILE.write_text(
        "\n".join(json.dumps(q, ensure_ascii=False, default=str) for q in updated),
        encoding="utf-8"
    )
    print(f"\nUpdated {QUESTIONS_FILE}")

    GT_RESULTS_FILE.write_text("\n".join(md_lines), encoding="utf-8")
    print(f"Report written to {GT_RESULTS_FILE}")
    print("\n" + "\n".join(md_lines))


if __name__ == "__main__":
    main()
