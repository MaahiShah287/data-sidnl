"""Loads parsed rows into Supabase (Postgres). Writes only to the `fp` and `ops` schemas; never touches
`public`. Storage is append-only:
  * identical row already stored  -> not stored again (only its last_seen_at is touched)
  * changed row                   -> new version appended, the old version stays for analysis
"""
from __future__ import annotations

import json
from datetime import date

import psycopg

from .parse import row_identity

BATCH = 2000

_UPSERT = """
with src as (
  select * from unnest(%(keys)s::text[], %(hashes)s::text[], %(data)s::text[]) as t(row_key, row_hash, row_data)
), ins as (
  insert into fp.report_rows (brand, platform, report_type, row_key, row_hash, window_start, window_end,
                              source_file_id, row_data)
  select %(brand)s, 'zepto', %(report)s, row_key, row_hash, %(ws)s, %(we)s, %(fid)s, row_data::jsonb from src
  on conflict (brand, report_type, row_key, row_hash) do update set last_seen_at = now()
  returning (xmax = 0) as inserted
)
select count(*) filter (where inserted), count(*) filter (where not inserted) from ins
"""


def connect(db_url: str) -> psycopg.Connection:
    return psycopg.connect(db_url, autocommit=False)


# ---- manifest -------------------------------------------------------------------------------------

def already_loaded(conn, brand: str, report_key: str, start: date, end: date) -> bool:
    cur = conn.execute(
        "select 1 from ops.fp_ingest_files where brand=%s and report_key=%s and window_start=%s "
        "and window_end=%s and status='loaded' limit 1",
        (brand, report_key, start, end),
    )
    return cur.fetchone() is not None


def same_file_loaded(conn, brand: str, report_key: str, sha256: str) -> bool:
    """True if a byte-identical file was already loaded: nothing new can be in it."""
    cur = conn.execute(
        "select 1 from ops.fp_ingest_files where brand=%s and report_key=%s and sha256=%s "
        "and status='loaded' limit 1",
        (brand, report_key, sha256),
    )
    return cur.fetchone() is not None


def start_file(conn, *, brand, report_key, label, start, end, request_id, file_name, sha256) -> int:
    cur = conn.execute(
        "insert into ops.fp_ingest_files(brand, report_key, report_label, window_start, window_end, "
        "request_id, file_name, sha256, status) values (%s,%s,%s,%s,%s,%s,%s,%s,'downloaded') returning id",
        (brand, report_key, label, start, end, request_id, file_name, sha256),
    )
    file_id = cur.fetchone()[0]
    conn.commit()
    return file_id


def finish_file(conn, file_id: int, new: int, unchanged: int, status: str = "loaded", error: str | None = None) -> None:
    conn.execute(
        "update ops.fp_ingest_files set status=%s, rows_new=%s, rows_unchanged=%s, error=%s, finished_at=now() "
        "where id=%s",
        (status, new, unchanged, error, file_id),
    )
    conn.commit()


def record_failure(conn, *, brand, report_key, label, start, end, error: str) -> None:
    conn.execute(
        "insert into ops.fp_ingest_files(brand, report_key, report_label, window_start, window_end, status, error, "
        "finished_at) values (%s,%s,%s,%s,%s,'failed',%s, now())",
        (brand, report_key, label, start, end, error[:2000]),
    )
    conn.commit()


# ---- rows -----------------------------------------------------------------------------------------

def upsert_rows(conn, *, file_id: int, brand: str, report_key: str, start: date, end: date,
                rows: list[dict], key_columns: list[str]) -> tuple[int, int]:
    """Returns (new_versions_appended, unchanged_rows). Does not commit (the caller commits rows and
    manifest together)."""
    # identical rows inside one file collapse to one (a single statement cannot touch a row twice)
    uniq: dict[tuple[str, str], dict] = {}
    for r in rows:
        uniq.setdefault(row_identity(r, key_columns), r)

    items = list(uniq.items())
    new = unchanged = 0
    with conn.cursor() as cur:
        for i in range(0, len(items), BATCH):
            chunk = items[i:i + BATCH]
            cur.execute(_UPSERT, {
                "keys": [k for (k, _), _ in chunk],
                "hashes": [h for (_, h), _ in chunk],
                "data": [json.dumps(r, ensure_ascii=False) for _, r in chunk],
                "brand": brand, "report": report_key, "ws": start, "we": end, "fid": file_id,
            })
            n, u = cur.fetchone()
            new += n
            unchanged += u
    return new, unchanged


# ---- accounts (one per onboarded company) -----------------------------------------------------------

def register_account(conn, *, name: str, brand: str, email: str, otp_route: str) -> None:
    conn.execute(
        "insert into ops.fp_accounts(name, brand, zepto_email, otp_route) values (%s,%s,%s,%s) "
        "on conflict (name) do update set brand=excluded.brand, zepto_email=excluded.zepto_email, "
        "otp_route=excluded.otp_route, active=true",
        (name, brand, email, otp_route),
    )
    conn.commit()


def list_accounts(conn, only: str | None = None) -> list[dict]:
    cur = conn.execute(
        "select name, brand, zepto_email, otp_route from ops.fp_accounts where active "
        "and (%s::text is null or name = %s) order by name",
        (only, only),
    )
    return [dict(name=n, brand=b, email=e, otp_route=r) for n, b, e, r in cur.fetchall()]


def touch_account(conn, name: str, status: str) -> None:
    conn.execute("update ops.fp_accounts set last_run_at=now(), last_run_status=%s where name=%s", (status[:500], name))
    conn.commit()
