"""
db/safe_sql.py  — SQL validator for the SIDNL chatbot (Phase 1, restored).
"""
from __future__ import annotations
import re
from dataclasses import dataclass, field
from typing import Any

import sqlglot
import sqlglot.expressions as exp

from db.schema_guard import find_bad_date_column
from db.silver_fast_path import rewrite_latest_views

# ---------------------------------------------------------------------------
# Allowlist
# ---------------------------------------------------------------------------
# Two layers are readable:
#   * Silver — raw, quality-filtered SKU x store readings (price, stock, shelf).
#   * Gold (dash) — pre-aggregated dashboard tables/views (OSA, SOV, pricing
#     parity, competitor layer, first-party sales/ads/finance).
#
# The database grant is deliberately broad (SELECT on the whole dash schema);
# THIS set is the real guardrail. Anything not listed here is rejected before
# it reaches Postgres. Keep it curated: adding a relation means the planner can
# use it and the model may see its columns.

SILVER_RELATIONS: frozenset[str] = frozenset({
    "silver.v_all_platforms",
    "silver.v_latest_observation",
    "silver.v_latest_shelf_position",
})

# Gold fact tables (daily aggregates, one row per grain in the comment).
GOLD_TABLES: frozenset[str] = frozenset({
    "dash.availability",        # SKU x city x day OSA/inventory; store_key NULL = city total
    "dash.pricing",             # SKU x city x day MRP/SP/discount + parity
    "dash.visibility",          # SKU x category/keyword x day rank/impressions/SOV
    "dash.coverage",            # day x platform x city serviceability
    "dash.comp_brand_day",      # competitor brand x category x city x day
    "dash.comp_sku_day",        # competitor SKU x city x day
    "dash.fp_sales_daily",      # first-party sales: date x SKU x city (GMV, units)
    "dash.fp_ad_page_perf",     # first-party ad page: impressions/clicks/orders/spend
    "dash.fp_ad_wallet_txn",    # first-party ad wallet debits/credits
    "dash.fp_fill_rate",        # weekly quantity/line fill rate
    "dash.fp_sku",              # first-party SKU master
    "dash.fp_sku_name",         # first-party SKU -> name
    "dash.fp_product_snapshot", # first-party product snapshot (stock, GMV, growth)
    "dash.metric_catalog",      # authoritative metric list: formula/status/gold_table
    "dash.refresh_table_state", # Gold refresh status per table
    "dash.fp_po",               # purchase orders
    "dash.fp_po_line",          # purchase order lines
    "dash.fp_grn_line",         # goods receipt lines (ASN/GRN/invoice)
    "dash.fp_invoice",          # invoices
    "dash.fp_payment_advice",   # payment advices
    "dash.fp_debit_credit_note",# debit / credit notes
    "dash.fp_ledger_entry",     # ledger entries / running balance
    "dash.fp_new_user_share",   # new-user share by month
})

GOLD_DIMENSIONS: frozenset[str] = frozenset({
    "dash.dim_brand",
    "dash.dim_city",        # city_slug + city_name; pseudo-city 'ALL'
    "dash.dim_platform",
    "dash.dim_store",
    "dash.dim_sidnl",       # sidnl_id -> canonical product
    "dash.dim_product",
    "dash.dim_category",
    "dash.dim_date",
})

# Pre-built Gold views. Prefer these over re-deriving the same aggregate.
GOLD_VIEWS: frozenset[str] = frozenset({
    "dash.v_brand_scorecard",
    "dash.v_brand_scorecard_latest",
    "dash.v_comp_price_gap",
    "dash.v_comp_sku_day",
    "dash.v_comp_cross_marketplace",
    "dash.v_fp_sales_day",
    "dash.v_fp_sales_sku",
    "dash.v_fp_sales_city",
    "dash.v_fp_sales_month",
    "dash.v_fp_sales_health",
    "dash.v_fp_ad_page",
    "dash.v_fp_ad_wallet_day",
    "dash.v_fp_sku_stock",
    "dash.v_fp_sku_cost",
    "dash.v_fp_po_summary",
    "dash.v_fp_po_status",
    "dash.v_fp_po_month",
    "dash.v_fp_po_sku",
    "dash.v_fp_po_line_all",
    "dash.v_fp_invoice_recon",
    "dash.v_fp_finance_summary",
    "dash.v_fp_debit_note_month",
    "dash.v_workspace_sov_keyword",
    "dash.v_refresh_status",
    "dash.v_data_freshness",
    "dash.v_platform_freshness",
    "dash.v_chatbot_availability_city",  # city-level only (store_key IS NULL)
})

ALLOWLISTED_RELATIONS: frozenset[str] = (
    SILVER_RELATIONS | GOLD_TABLES | GOLD_DIMENSIONS | GOLD_VIEWS
)

_BLOCKED: list[re.Pattern] = [
    re.compile(r"\bINSERT\b",        re.IGNORECASE),
    re.compile(r"\bUPDATE\b",        re.IGNORECASE),
    re.compile(r"\bDELETE\b",        re.IGNORECASE),
    re.compile(r"\bDROP\b",          re.IGNORECASE),
    re.compile(r"\bALTER\b",         re.IGNORECASE),
    re.compile(r"\bCREATE\b",        re.IGNORECASE),
    re.compile(r"\bGRANT\b",         re.IGNORECASE),
    re.compile(r"\bREVOKE\b",        re.IGNORECASE),
    re.compile(r"\bTRUNCATE\b",      re.IGNORECASE),
    re.compile(r"\bCOPY\b",          re.IGNORECASE),
    re.compile(r"\bEXECUTE\b",       re.IGNORECASE),
    re.compile(r"\bCALL\b",          re.IGNORECASE),
    re.compile(r"\bpg_sleep\b",      re.IGNORECASE),
    re.compile(r"\bpg_read_file\b",  re.IGNORECASE),
    re.compile(r"\bpg_ls_dir\b",     re.IGNORECASE),
    re.compile(r"\blo_export\b",     re.IGNORECASE),
    re.compile(r"\blo_import\b",     re.IGNORECASE),
    re.compile(r"\bdblink\b",        re.IGNORECASE),
    re.compile(r";.{1,}",            re.DOTALL),
]

DEFAULT_LIMIT = 200


@dataclass
class SafeResult:
    sanitised_sql: str
    limit_was_added: bool
    rewritten_for_performance: bool = False
    rows: list[dict[str, Any]] = field(default_factory=list)
    row_count: int = 0
    observed_at_min: str | None = None
    observed_at_max: str | None = None
    execution_time_ms: float | None = None


class SQLValidationError(ValueError):
    pass


def _strip_semi(sql: str) -> str:
    return sql.rstrip().rstrip(";").rstrip()


def _check_blocked(sql: str) -> None:
    for p in _BLOCKED:
        if p.search(sql):
            raise SQLValidationError(
                f"Rejected: blocked keyword/pattern '{p.pattern}'. Only SELECT is permitted."
            )


def _parse(sql: str) -> sqlglot.Expression:
    try:
        stmts = [s for s in sqlglot.parse(sql, dialect="postgres") if s is not None]
    except sqlglot.errors.ParseError as exc:
        raise SQLValidationError(f"Parse error: {exc}") from exc
    if not stmts:
        raise SQLValidationError("Rejected: no SQL statement found.")
    if len(stmts) > 1:
        raise SQLValidationError(f"Rejected: {len(stmts)} statements; only 1 allowed.")
    stmt = stmts[0]
    root = stmt.this if isinstance(stmt, exp.With) else stmt
    if not isinstance(root, (exp.Select, exp.Union)):
        raise SQLValidationError(f"Rejected: expected SELECT, got {type(root).__name__}.")
    return stmt


def _cte_names(parsed: sqlglot.Expression) -> set[str]:
    names: set[str] = set()
    for cte in parsed.find_all(exp.CTE):
        alias = cte.args.get("alias")
        if isinstance(alias, exp.TableAlias):
            ident = alias.args.get("this")
            n = ident.name if isinstance(ident, exp.Identifier) else str(ident)
        elif isinstance(alias, exp.Identifier):
            n = alias.name
        else:
            n = str(alias) if alias else ""
        if n:
            names.add(n.lower())
    return names


def _relations(parsed: sqlglot.Expression) -> set[str]:
    skip = _cte_names(parsed)
    rels: set[str] = set()
    for t in parsed.find_all(exp.Table):
        schema = t.args.get("db")
        name = t.args.get("this")
        schema = schema.name if isinstance(schema, exp.Identifier) else (schema or None)
        name = name.name if isinstance(name, exp.Identifier) else (name or None)
        if not name:
            continue
        full = f"{schema.lower()}.{name.lower()}" if schema else name.lower()
        if full not in skip:
            rels.add(full)
    return rels


def _has_limit(parsed: sqlglot.Expression) -> bool:
    root = parsed.this if isinstance(parsed, exp.With) else parsed
    if isinstance(root, (exp.Select, exp.Union)):
        return root.args.get("limit") is not None
    return False


def validate_and_sanitise(raw_sql: str, *, skip_fast_path: bool = False) -> SafeResult:
    """
    Validate and sanitise one read-only SELECT.

    skip_fast_path=True disables the deterministic DISTINCT ON rewrite. Callers
    set it when silver.v_latest_observation / v_latest_shelf_position are backed
    by populated materialised views, where the plain view is much faster than
    the inline rewrite over the base tables (see db/client.py).
    """
    if not raw_sql or not raw_sql.strip():
        raise SQLValidationError("Rejected: empty SQL.")
    sql = _strip_semi(raw_sql.strip())
    _check_blocked(sql)
    # Deterministic fast path: a filtered query on v_latest_observation /
    # v_latest_shelf_position is rewritten to an inline DISTINCT ON over
    # v_all_platforms so the filter is pushed down (see db/silver_fast_path.py).
    # The rewrite is semantic-preserving (scope columns only) and idempotent.
    if skip_fast_path:
        rewritten = False
    else:
        sql, rewritten = rewrite_latest_views(sql)
    _check_blocked(sql)
    parsed = _parse(sql)
    rels = _relations(parsed)
    for r in rels:
        if r not in ALLOWLISTED_RELATIONS:
            raise SQLValidationError(
                f"Rejected: '{r}' not in the allowlist. "
                "Only the curated Silver views and Gold (dash) tables/views in "
                "src/db/safe_sql.py are readable; silver.demo, base scraped "
                "tables and config/ops schemas are permanently excluded."
            )

    bad_date = find_bad_date_column(parsed)
    if bad_date:
        rel, col, allowed = bad_date
        if allowed:
            allowed_txt = ", ".join(sorted(allowed))
            fix = (
                f"Use one of its real date columns: {allowed_txt}. "
                "Never invent a date column."
            )
        else:
            fix = (
                "It has no date column at all (snapshot view). Do not filter or "
                "group by a date on it; aggregate across all rows and group by "
                "snapshot_label / page_name instead."
            )
        raise SQLValidationError(
            f"Rejected: '{rel}' has no column '{col}'. {fix}"
        )

    had_limit = _has_limit(parsed)
    if not had_limit:
        sql = f"{sql}\nLIMIT {DEFAULT_LIMIT}"
    return SafeResult(
        sanitised_sql=sql,
        limit_was_added=not had_limit,
        rewritten_for_performance=rewritten,
    )


def validate_and_sanitise_safe(
    raw_sql: str, *, skip_fast_path: bool = False
) -> tuple[SafeResult | None, str | None]:
    try:
        return validate_and_sanitise(raw_sql, skip_fast_path=skip_fast_path), None
    except SQLValidationError as exc:
        return None, str(exc)
