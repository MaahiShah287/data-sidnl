"""
db/safe_sql.py  — SQL validator for the SIDNL chatbot (Phase 1, restored).
"""
from __future__ import annotations
import re
from dataclasses import dataclass, field
from typing import Any

import sqlglot
import sqlglot.expressions as exp

ALLOWLISTED_RELATIONS: frozenset[str] = frozenset({
    "silver.v_all_platforms",
    "silver.v_latest_observation",
    "silver.v_latest_shelf_position",
})

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


def validate_and_sanitise(raw_sql: str) -> SafeResult:
    if not raw_sql or not raw_sql.strip():
        raise SQLValidationError("Rejected: empty SQL.")
    sql = _strip_semi(raw_sql.strip())
    _check_blocked(sql)
    parsed = _parse(sql)
    rels = _relations(parsed)
    for r in rels:
        if r not in ALLOWLISTED_RELATIONS:
            raise SQLValidationError(
                f"Rejected: '{r}' not in the allowlist {sorted(ALLOWLISTED_RELATIONS)}. "
                "silver.demo and base tables are permanently excluded."
            )
    had_limit = _has_limit(parsed)
    if not had_limit:
        sql = f"{sql}\nLIMIT {DEFAULT_LIMIT}"
    return SafeResult(sanitised_sql=sql, limit_was_added=not had_limit)


def validate_and_sanitise_safe(raw_sql: str) -> tuple[SafeResult | None, str | None]:
    try:
        return validate_and_sanitise(raw_sql), None
    except SQLValidationError as exc:
        return None, str(exc)
