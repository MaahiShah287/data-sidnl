"""
db/schema_guard.py — reject impossible date columns on Gold (dash) relations.

The SQL planner is an LLM. It occasionally invents a date column — most often
``day`` — on a view that has none, e.g.:

    SELECT day, SUM(spend) FROM dash.v_fp_ad_page GROUP BY day
    -- ERROR: column "day" does not exist in dash.v_fp_ad_page

That costs a repair round trip (an extra LLM call) and, on a rate-limited
provider, can turn into an abstain. This check catches the mistake before the
query reaches Postgres and hands the model the exact date columns the relation
actually exposes.

The column list is generated from ``information_schema.columns`` by
``scripts/dump_dash_schema.py``; it is not hand-maintained.
"""
from __future__ import annotations

import sqlglot.expressions as exp

from db.dash_schema import DASH_DATE_COLUMNS

# Column names that are unambiguously date/time references. Deliberately
# conservative: only names that could not plausibly be a non-date column.
# `snapshot_label` is intentionally absent — it is text, not a date.
DATE_LIKE_COLUMNS: frozenset[str] = frozenset({
    # common / generic
    "day", "date", "report_date", "report_day", "event_date", "obs_at",
    "obs_date", "sale_date", "sales_date", "txn_date",
    # scraped Gold
    "prior_obs_date", "observed_at", "refreshed_at", "last_observed_at",
    "date_key", "date_from", "date_to",
    # first-party sales / ads / stock
    "as_of", "month", "snapshot_at", "cost_date", "last_sale",
    "created_at", "updated_at", "loaded_at",
    # first-party supply chain / finance
    "booked_at", "posted_at", "document_date", "clearing_at", "paid_at",
    "po_date", "po_created_at", "po_approved_at", "po_expiry_at",
    "po_delivery_at", "po_cancelled_at", "po_delivery_date", "po_expiry_date",
    "asn_date", "asn_confirmed_at", "grn_date", "first_grn_date",
    "invoice_date",
    # freshness / monitoring
    "last_data_at", "last_refreshed_at", "last_attempt_at", "next_retry_at",
    "last_ok_at", "last_failed_at", "status_since",
    # workspace
    "period_start", "period_end",
})


def _name(node: object) -> str | None:
    if isinstance(node, exp.Identifier):
        return node.name.lower()
    if node is None:
        return None
    text = str(node).strip().lower()
    return text or None


def find_bad_date_column(
    parsed: exp.Expression,
) -> tuple[str, str, frozenset[str]] | None:
    """
    Return ``(relation, column, allowed_date_columns)`` for the first date-like
    column that the referenced ``dash.*`` relation does not actually have.

    Unqualified columns are only checked when the query touches exactly one dash
    relation, and are skipped when they name a SELECT alias (``... AS day`` then
    ``GROUP BY day``). That keeps the check free of false positives.
    """
    alias_map: dict[str, set[str]] = {}
    dash_relations: set[str] = set()

    for table in parsed.find_all(exp.Table):
        schema = _name(table.args.get("db"))
        relation = _name(table.args.get("this"))
        if schema != "dash" or not relation:
            continue
        full = f"dash.{relation}"
        dash_relations.add(full)

        alias = table.args.get("alias")
        if isinstance(alias, exp.TableAlias):
            key = _name(alias.args.get("this"))
            if key:
                alias_map.setdefault(key, set()).add(full)
        alias_map.setdefault(relation, set()).add(full)

    if not dash_relations:
        return None

    output_aliases = {
        str(a.alias).lower()
        for a in parsed.find_all(exp.Alias)
        if a.alias
    }
    single_relation = next(iter(dash_relations)) if len(dash_relations) == 1 else None

    for column in parsed.find_all(exp.Column):
        col = column.name.lower()
        if col not in DATE_LIKE_COLUMNS:
            continue

        qualifier = _name(column.args.get("table"))
        if qualifier:
            candidates = alias_map.get(qualifier)
            if not candidates or len(candidates) != 1:
                continue
            relation = next(iter(candidates))
        else:
            if col in output_aliases:
                continue
            relation = single_relation
            if relation is None:
                continue

        allowed = DASH_DATE_COLUMNS.get(relation)
        if allowed is None:
            continue  # unknown relation: the allowlist check owns that
        if col not in allowed:
            return relation, col, allowed

    return None
