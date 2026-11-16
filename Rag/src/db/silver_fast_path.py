"""
db/silver_fast_path.py — deterministic rewrite of filtered Silver "latest" queries.

Why
---
`silver.v_latest_observation` and `silver.v_latest_shelf_position` are
`DISTINCT ON (...) ... FROM silver.v_all_platforms` views. Postgres cannot push
a brand / product / platform / city / store filter through the DISTINCT ON, so
a filtered query on either view rebuilds and sorts every row in
`v_all_platforms` (a 4-branch UNION ALL over `silver.blinkit` / `zepto` /
`instamart` / `jiomart`, which are views over `silver.v_wide`; its physical
fact table is `silver.fact_product_reading`, 260k rows). Measured 8.9 s for a
simple brand+platform price query, which trips the 10 s statement_timeout.

What
----
For a single-table SELECT over one of those views, rewrite:

    SELECT ... FROM silver.v_latest_observation [v]
     WHERE brand = 'X' AND platform = 'blinkit' AND <other>

into:

    SELECT ... FROM (
      SELECT DISTINCT ON (platform, COALESCE(listing_id::text, platform_product_id), store_id) *
        FROM silver.v_all_platforms
       WHERE source_type = 'observation' AND brand = 'X' AND platform = 'blinkit'
       ORDER BY platform, COALESCE(listing_id::text, platform_product_id), store_id,
                observed_at DESC
    ) AS v
     WHERE <other>

The pushed-down predicate list is deliberately restricted to identity / scope
columns (brand, platform, product_name, city, store_id, ...). Those are constant
within a (platform, listing, store) group, so filtering before the DISTINCT ON
is semantically identical to filtering after it. Predicates on value columns
(`sale_price > 100`, `availability = true`, `observed_at >= ...`) are NOT pushed
down, because they would select a different "latest" row.

Status
------
This is now the **fallback**, not the primary path. The owner script
`Rag/sql/05_latest_observation_mv.sql` creates materialised views behind both
public views (refreshed every 15 minutes by `pg_cron`). `db/client.py`'s
`latest_views_use_mv()` detects that state and passes `skip_fast_path=True` to
`safe_sql.validate_and_sanitise`, so filtered queries stay on the fast
materialised views (~15-100 ms). If the MVs are missing, unpopulated or the
public views are still on `v_all_platforms`, the rewrite below fires and keeps
Silver queries well under the 10 s statement timeout (~0.1-0.9 s).

The owner script also adds a selective partial index on the real table
`silver.fact_product_reading` (the four `silver.blinkit/zepto/...` relations
are views), so the inline fallback stays fast.
"""
from __future__ import annotations

import sqlglot
import sqlglot.expressions as exp

SLOW_VIEWS: dict[str, str] = {
    "silver.v_latest_observation": "observation",
    "silver.v_latest_shelf_position": "shelf_position",
}

_DISTINCT_ON = "platform, COALESCE(listing_id::text, platform_product_id), store_id"
_ORDER_BY = f"{_DISTINCT_ON}, observed_at DESC"

# Columns that are constant per (platform, listing, store) group, so filtering
# before the DISTINCT ON cannot change which row is "latest".
_PUSHDOWN_SAFE_COLUMNS: frozenset[str] = frozenset({
    "platform",
    "brand",
    "product_name",
    "sku_name",
    "sku_code",
    "variant",
    "listing_id",
    "platform_product_id",
    "product_id",
    "store_id",
    "store_name",
    "store_external_id",
    "city",
    "city_slug",
    "state",
    "pincode",
    "l1_id",
    "l1_category",
    "l2_id",
    "l2_category",
    "l3_id",
    "l3_category",
    "category_path",
    "pack_size",
    "pack_unit",
})


def _table_full_name(table: exp.Table) -> str:
    db = table.args.get("db")
    name = table.args.get("this")
    db = db.name if isinstance(db, exp.Identifier) else (db or "")
    name = name.name if isinstance(name, exp.Identifier) else (name or "")
    return f"{db.lower()}.{name.lower()}" if db else name.lower()


def _split_and(node: exp.Expression) -> list[exp.Expression]:
    if isinstance(node, exp.And):
        return _split_and(node.this) + _split_and(node.expression)
    return [node]


def _is_pushdown_safe(node: exp.Expression, alias: str) -> bool:
    """True when every column is scope-only and belongs to the rewritten table."""
    if node.find(exp.Subquery) or node.find(exp.Select):
        return False
    columns = list(node.find_all(exp.Column))
    if not columns:
        return False
    for col in columns:
        table = col.args.get("table")
        if isinstance(table, exp.Identifier) and table.name.lower() != alias.lower():
            return False
        if col.name.lower() not in _PUSHDOWN_SAFE_COLUMNS:
            return False
    return True


def _strip_alias(node: exp.Expression, alias: str) -> exp.Expression:
    """Drop `v.` from `v.brand` so the predicate is valid inside the subquery."""
    def _drop(n: exp.Expression) -> exp.Expression:
        if isinstance(n, exp.Column):
            table = n.args.get("table")
            if isinstance(table, exp.Identifier) and table.name.lower() == alias.lower():
                n.set("table", None)
        return n

    return node.transform(_drop)


def rewrite_latest_views(sql: str) -> tuple[str, bool]:
    """
    Rewrite filtered queries on the slow Silver latest views.

    Returns (sql, changed). On any parse problem the original SQL is returned
    unchanged so normal validation can report the real error.
    """
    try:
        parsed = sqlglot.parse_one(sql, dialect="postgres")
    except Exception:
        return sql, False
    if parsed is None:
        return sql, False

    changed = False
    generated = 0

    for select in list(parsed.find_all(exp.Select)):
        # sqlglot 30 stores the FROM clause under "from_"; older versions used
        # "from". Accept both so the rewrite survives an upgrade/downgrade.
        from_ = select.args.get("from_") or select.args.get("from")
        if from_ is None:
            continue
        # Only the single-table shape. A join makes unqualified column
        # ownership ambiguous, so leave it alone.
        if select.args.get("joins"):
            continue
        table = from_.this
        if not isinstance(table, exp.Table):
            continue
        source_type = SLOW_VIEWS.get(_table_full_name(table))
        if source_type is None:
            continue

        alias_node = table.args.get("alias")
        alias = alias_node.name if isinstance(alias_node, exp.TableAlias) else ""
        if not alias:
            generated += 1
            kind = "shelf" if source_type == "shelf_position" else "obs"
            alias = f"latest_{kind}_{generated}"

        where = select.args.get("where")
        conjuncts = _split_and(where.this) if where is not None else []
        safe_flags = [_is_pushdown_safe(c, alias) for c in conjuncts]
        safe = [c for c, ok in zip(conjuncts, safe_flags) if ok]
        keep = [c for c, ok in zip(conjuncts, safe_flags) if not ok]

        # Nothing to push down: the rewrite would cost the same as the view.
        # (The materialized view in Rag/sql/05_latest_observation_mv.sql is the
        # fix for unfiltered reads.)
        if not safe:
            continue

        if where is not None:
            if keep:
                combined = keep[0]
                for extra in keep[1:]:
                    combined = exp.And(this=combined, expression=extra)
                where.set("this", combined)
            else:
                select.set("where", None)

        pred_sql = "".join(
            f" AND {_strip_alias(c, alias).sql(dialect='postgres')}" for c in safe
        )
        inner_sql = (
            f"SELECT DISTINCT ON ({_DISTINCT_ON}) * "
            f"FROM silver.v_all_platforms "
            f"WHERE source_type = '{source_type}'{pred_sql} "
            f"ORDER BY {_ORDER_BY}"
        )
        try:
            inner = sqlglot.parse_one(inner_sql, dialect="postgres")
        except Exception:
            return sql, False
        subquery = exp.Subquery(
            this=inner,
            alias=exp.TableAlias(this=exp.to_identifier(alias)),
        )
        table.replace(subquery)
        changed = True

    if not changed:
        return sql, False
    return parsed.sql(dialect="postgres"), True
