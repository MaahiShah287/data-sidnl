"""
scripts/dump_dash_schema.py
===========================
Regenerate ``src/db/dash_schema.py`` from the live database.

The planner is an LLM: it will sometimes invent a date column (most often
``day``) on a Gold view that has none. The authoritative column list comes from
``information_schema.columns``, not from prompt text, so this script snapshots
it into Python that the SQL guard can import.

Read-only. Uses ``get_bulk_conn`` because ``information_schema`` is outside the
chatbot's own allowlist (the chatbot never runs this query).

Usage:
    .\\.venv\\Scripts\\python.exe scripts\\dump_dash_schema.py
"""
from __future__ import annotations

import datetime as _dt
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from db.client import get_bulk_conn  # noqa: E402

OUT = ROOT / "src" / "db" / "dash_schema.py"
DATE_TYPES = ("date", "timestamp with time zone", "timestamp without time zone")


def fetch() -> list[tuple[str, str, str]]:
    with get_bulk_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT table_name, column_name, data_type
                FROM information_schema.columns
                WHERE table_schema = 'dash'
                ORDER BY table_name, ordinal_position
                """
            )
            return list(cur.fetchall())


def render(rows: list[tuple[str, str, str]]) -> str:
    tables: dict[str, list[tuple[str, str]]] = {}
    for table, column, dtype in rows:
        tables.setdefault(table, []).append((column, dtype))

    stamp = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    lines = [
        '"""GENERATED FILE - do not edit by hand.',
        "",
        "Exact column names and types for every relation in the Gold (`dash`)",
        "schema, captured from information_schema.columns.",
        "",
        "Regenerate with:",
        "    .\\\\.venv\\\\Scripts\\\\python.exe scripts\\\\dump_dash_schema.py",
        "",
        f"Captured at: {stamp}",
        f"Relations: {len(tables)}, columns: {len(rows)}",
        '"""',
        "from __future__ import annotations",
        "",
        "DATE_TYPES: frozenset[str] = frozenset({",
    ]
    for t in DATE_TYPES:
        lines.append(f'    "{t}",')
    lines.append("})")
    lines.append("")
    lines.append("DASH_COLUMNS: dict[str, dict[str, str]] = {")
    for table in sorted(tables):
        lines.append(f'    "{table}": {{')
        for column, dtype in tables[table]:
            lines.append(f'        "{column}": "{dtype}",')
        lines.append("    },")
    lines.append("}")
    lines.append("")
    lines.append("# dash.<relation> -> the date/time columns it actually exposes.")
    lines.append("DASH_DATE_COLUMNS: dict[str, frozenset[str]] = {")
    lines.append('    f"dash.{rel}": frozenset(')
    lines.append("        col for col, dtype in cols.items() if dtype in DATE_TYPES")
    lines.append("    )")
    lines.append("    for rel, cols in DASH_COLUMNS.items()")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    rows = fetch()
    if not rows:
        print("No dash columns found. Is the database reachable?", file=sys.stderr)
        return 1
    OUT.write_text(render(rows), encoding="utf-8")
    print(f"wrote {OUT} ({len(rows)} columns)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
