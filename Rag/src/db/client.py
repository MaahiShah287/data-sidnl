"""
src/db/client.py — Read-only Postgres client for the SIDNL chatbot.
Wraps psycopg3 with a connection pool and enforces read-only mode.
"""
from __future__ import annotations

import time
from contextlib import contextmanager
from typing import Any, Generator

try:
    import psycopg
    import psycopg_pool
    _PSYCOPG_AVAILABLE = True
except ImportError:
    _PSYCOPG_AVAILABLE = False

from config import settings
from db.safe_sql import SafeResult, SQLValidationError, validate_and_sanitise

_pool: "psycopg_pool.ConnectionPool | None" = None


def _get_pool() -> "psycopg_pool.ConnectionPool":
    global _pool
    if _pool is None:
        if not _PSYCOPG_AVAILABLE:
            raise RuntimeError("psycopg not installed. Run: pip install psycopg[binary] psycopg-pool")
        if not settings.database_url:
            raise RuntimeError("DATABASE_URL not configured in .env")
        _pool = psycopg_pool.ConnectionPool(
            conninfo=settings.database_url,
            min_size=1,
            max_size=5,
            kwargs={"options": "-c default_transaction_read_only=on -c statement_timeout=10000"},
        )
    return _pool


@contextmanager
def get_conn() -> Generator:
    pool = _get_pool()
    with pool.connection() as conn:
        yield conn


BULK_STATEMENT_TIMEOUT_MS = 600_000


# ---------------------------------------------------------------------------
# Latest-view materialisation detection
# ---------------------------------------------------------------------------
# silver.v_latest_observation / v_latest_shelf_position used to be DISTINCT ON
# views over silver.v_all_platforms, so a filtered query scanned and sorted the
# whole fact table (~9 s). db/silver_fast_path.py rewrites such queries to an
# inline DISTINCT ON so the filter pushes down (~0.1-0.9 s).
#
# Once the owner script (Rag/sql/05_latest_observation_mv.sql) has populated the
# materialised views and repointed the public views at them, the plain view is
# much faster than that rewrite (~15-100 ms). This flag lets the app use the
# views again. It is cached and fails safe: any error, missing object or
# unpopulated MV keeps the rewrite, which still works on the base tables.
_LATEST_MV_TTL_S = 300.0
_latest_mv_cache: tuple[float, bool] | None = None

_LATEST_MV_QUERY = """
    SELECT count(*)
      FROM (VALUES
              ('silver.v_latest_observation', 'mv_latest_observation'),
              ('silver.v_latest_shelf_position', 'mv_latest_shelf_position')
           ) AS v(view_name, mv_name)
     WHERE EXISTS (
             SELECT 1
               FROM pg_rewrite r
               JOIN pg_depend d ON d.objid = r.oid
               JOIN pg_class c ON c.oid = d.refobjid
              WHERE r.ev_class = v.view_name::regclass
                AND c.relkind = 'm'
                AND c.relname = v.mv_name
                AND c.relispopulated
           )
"""


def latest_views_use_mv() -> bool:
    """
    True when both public latest views read a *populated* materialised view.

    Cached for 5 minutes so a chat turn costs at most one cheap catalog query.
    Returns False on any problem (no DATABASE_URL, permissions, missing
    objects), so the DISTINCT ON rewrite stays the safe default.
    """
    global _latest_mv_cache
    now = time.monotonic()
    if _latest_mv_cache is not None and now - _latest_mv_cache[0] < _LATEST_MV_TTL_S:
        return _latest_mv_cache[1]

    ok = False
    try:
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(_LATEST_MV_QUERY)
                ok = cur.fetchone()[0] == 2
    except Exception:
        ok = False

    _latest_mv_cache = (now, ok)
    return ok


def reset_latest_mv_cache() -> None:
    """Clear the cached materialisation flag (tests / after an owner rollout)."""
    global _latest_mv_cache
    _latest_mv_cache = None


@contextmanager
def get_bulk_conn(timeout_ms: int = BULK_STATEMENT_TIMEOUT_MS) -> Generator:
    """
    Direct read-only connection with a long statement_timeout, for BULK READS
    ONLY (index building / profiling).

    The pooled connections above keep their 10 s cap, which is the chatbot's
    guard against runaway LLM-generated SQL. Bulk loads legitimately need
    longer (e.g. SELECT * over v_all_platforms, 56k rows), so they get their
    own connection instead of relaxing the chatbot's guarantee. Read-only is
    still enforced by the server.
    """
    if not _PSYCOPG_AVAILABLE:
        raise RuntimeError("psycopg not installed. Run: pip install psycopg[binary] psycopg-pool")
    if not settings.database_url:
        raise RuntimeError("DATABASE_URL not configured in .env")
    with psycopg.connect(
        settings.database_url,
        options=(
            "-c default_transaction_read_only=on "
            f"-c statement_timeout={int(timeout_ms)}"
        ),
        connect_timeout=15,
    ) as conn:
        yield conn


def execute_safe(raw_sql: str) -> SafeResult:
    """
    Validate raw_sql via safe_sql, then execute against the read-only pool.
    Returns a populated SafeResult. Raises SQLValidationError or RuntimeError.

    Hard rules enforced here:
    - Only SELECTs on allowlisted views.
    - statement_timeout=10s via connection option.
    - No writes possible (read-only transaction).
    """
    # When the latest-observation materialised views are live, the plain views
    # are 5-50x faster than the DISTINCT ON rewrite over the base tables.
    result = validate_and_sanitise(
        raw_sql, skip_fast_path=latest_views_use_mv()
    )  # raises SQLValidationError if unsafe

    start = time.monotonic()
    try:
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(result.sanitised_sql)
                cols = [d.name for d in cur.description]
                rows = [dict(zip(cols, row)) for row in cur.fetchall()]
    except Exception as exc:
        raise RuntimeError(f"Query execution failed: {exc}") from exc

    elapsed_ms = (time.monotonic() - start) * 1000

    # Extract observed_at window for provenance
    obs_min = obs_max = None
    if rows:
        observed_ats = [
            str(r["observed_at"]) for r in rows
            if r.get("observed_at") is not None
        ]
        if observed_ats:
            obs_min = min(observed_ats)
            obs_max = max(observed_ats)

    result.rows = rows
    result.row_count = len(rows)
    result.observed_at_min = obs_min
    result.observed_at_max = obs_max
    result.execution_time_ms = round(elapsed_ms, 1)
    return result


def close_pool() -> None:
    global _pool
    if _pool:
        _pool.close()
        _pool = None
