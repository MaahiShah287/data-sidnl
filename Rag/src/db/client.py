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
    result = validate_and_sanitise(raw_sql)  # raises SQLValidationError if unsafe

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
