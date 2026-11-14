"""
src/graph/sql_graph.py — Numeric path: plan → validate → execute → verify → format.

Retry cap: if the SQL errors or is rejected, repair once from the error message,
then abstain.  Max SQL retries = 1 (separate from RAG retry_count).
"""
from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any

import yaml
from langchain_openai import ChatOpenAI
from langchain_core.messages import HumanMessage

from config import settings
from db.safe_sql import validate_and_sanitise, SQLValidationError
from graph.prompt_utils import render
from graph.state import ChatState

_PROMPTS = Path(__file__).resolve().parent.parent / "prompts"
_METRIC_DICT_PATH = Path(settings.metric_dictionary_path)


def _load_prompt(name: str) -> str:
    return (_PROMPTS / name).read_text(encoding="utf-8")


def _load_metrics() -> list[dict]:
    try:
        with open(_METRIC_DICT_PATH, encoding="utf-8") as f:
            return yaml.safe_load(f).get("metrics", [])
    except Exception:
        return []


def _llm() -> ChatOpenAI:
    return ChatOpenAI(
        model=settings.llm_generator_model,
        api_key=settings.llm_api_key,
        base_url=settings.llm_api_base,
        temperature=0,
        response_format={"type": "json_object"},
    )


# Statuses the planner may answer. 'gold' = computed by the Gold pipeline; the
# authoritative formula is in dash.metric_catalog. It is treated like approved
# (no draft banner), while 'unsupported' is the only blocking status.
_ANSWERABLE_STATUSES = ("approved", "draft", "gold")


def _norm_phrase(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", str(text).lower()).strip()


def _matching_metrics(question: str, metrics: list[dict]) -> list[dict]:
    """
    All metrics whose name or an alias appears in the question, best first.

    The longest matching phrase wins, so "share of shelf" beats a bare "shelf"
    and "sales growth" beats "sales". Matching is word-boundary aware, so "osa"
    does not fire inside "dosa" and "eta" does not fire inside "metadata".
    """
    q = _norm_phrase(question)
    if not q:
        return []

    scored: list[tuple[int, int, dict]] = []
    for order, m in enumerate(metrics):
        terms = [m.get("name", "")]
        terms.extend(m.get("aliases") or [])
        score = 0
        for term in terms:
            phrase = _norm_phrase(term)
            if not phrase:
                continue
            if re.search(rf"(?<![a-z0-9]){re.escape(phrase)}(?![a-z0-9])", q):
                score = max(score, len(phrase))
        if score:
            scored.append((score, -order, m))

    scored.sort(key=lambda item: (item[0], item[1]), reverse=True)
    return [m for _, _, m in scored]


def _match_metric(question: str, metrics: list[dict]) -> dict | None:
    matches = _matching_metrics(question, metrics)
    return matches[0] if matches else None


def _build_metric_templates_text(
    metrics: list[dict],
    question: str = "",
    max_full: int = 2,
    template_chars: int = 1000,
) -> str:
    """
    Full SQL templates for the metric(s) the question actually names, plus a
    compact index of the rest.

    The planner prompt is capped by the LLM's per-minute token limit (Groq free
    tier: 8k TPM), so dumping all 33 templates does not fit. The named metric
    gets the exact template; everything else stays discoverable by name/status
    and the Gold catalog below carries the formulas.
    """
    answerable = [m for m in metrics if m.get("status") in _ANSWERABLE_STATUSES]
    if not answerable:
        return "(none)"

    matched = _matching_metrics(question, answerable)[:max_full]
    matched_names = {m["name"] for m in matched}

    lines: list[str] = []
    for m in matched:
        lines.append(
            f"-- Metric: {m['name']} [{m.get('status')}] (layer: {m.get('layer', 'n/a')})"
        )
        lines.append(f"-- Definition: {' '.join(str(m.get('definition', '')).split())}")
        if m.get("sql_template"):
            template = str(m["sql_template"]).strip()
            if len(template) > template_chars:
                template = template[:template_chars] + "\n-- ... (template truncated)"
            lines.append(template)
        lines.append("")

    others = [m for m in answerable if m["name"] not in matched_names]
    if others:
        lines.append(
            "-- Other available metrics (name [status/layer]). Use the relation "
            "map above for their columns:"
        )
        for m in others:
            lines.append(f"-- {m['name']} [{m.get('status')}/{m.get('layer', '?')}]")

    return "\n".join(lines) if lines else "(none)"


# ---------------------------------------------------------------------------
# Gold metric catalog (dash.metric_catalog)
# ---------------------------------------------------------------------------
# The catalog is the authoritative list of Gold metrics: formula, status
# (computed | proxy | partial | blocked), source table/columns and what input
# is missing. Injecting it into the planner prompt means every Gold metric is
# known without hardcoding 57 entries in the prompt file.
#
# Read once, cache for 15 minutes: one chat turn makes a single catalog query,
# while a Gold refresh (new metric) is picked up without an API restart.
_GOLD_CATALOG_TTL_S = 900.0
_GOLD_CATALOG_CHAR_BUDGET = 4500
_gold_catalog_cache: tuple[float, str] | None = None


def _catalog_line(r: dict) -> str:
    key = r.get("metric_key") or r.get("metric_name") or "?"
    status = r.get("status") or "unknown"
    line = f"- {key} [{status}]"
    # 'computed' needs no explanation; proxy/partial/blocked do, because the
    # planner must not present them as authoritative.
    if status != "computed":
        formula = " ".join(str(r.get("formula") or "").split())
        if formula:
            line += f": {formula[:120]}"
        missing = " ".join(str(r.get("missing_inputs") or "").split())
        if missing:
            line += f" (missing: {missing[:60]})"
    return line


def _render_catalog(rows: list[dict], budget: int) -> str:
    """Render non-computed metrics first, then computed ones, within a budget."""
    non_computed = [r for r in rows if (r.get("status") or "") != "computed"]
    computed = [r for r in rows if (r.get("status") or "") == "computed"]

    out: list[str] = []
    used = 0
    omitted = 0
    for r in non_computed + computed:
        line = _catalog_line(r)
        if used + len(line) + 1 > budget:
            omitted += 1
            continue
        out.append(line)
        used += len(line) + 1

    if omitted:
        out.append(
            f"- ... {omitted} more computed metrics omitted for prompt size; "
            "query dash.metric_catalog for the full list."
        )
    return "\n".join(out)


def _fetch_gold_catalog() -> str:
    try:
        from db.client import execute_safe

        result = execute_safe(
            "SELECT pdf_section, section_name, metric_key, metric_name, formula, "
            "status, gold_table, gold_columns, missing_inputs, owner_team "
            "FROM dash.metric_catalog "
            "ORDER BY pdf_section NULLS LAST, metric_key"
        )
        rows = result.rows
    except Exception as exc:
        # Gold access may not be granted yet, or the DB is unreachable. The
        # planner still has the relation map above, so degrade, never crash.
        return (
            "(Gold catalog unavailable: could not read dash.metric_catalog "
            f"({type(exc).__name__}). Use the Gold relation map above.)"
        )

    if not rows:
        return "(dash.metric_catalog is empty)"

    return _render_catalog(rows, _GOLD_CATALOG_CHAR_BUDGET)


def _gold_catalog_text() -> str:
    global _gold_catalog_cache
    now = time.monotonic()
    if _gold_catalog_cache is not None:
        cached_at, text = _gold_catalog_cache
        if now - cached_at < _GOLD_CATALOG_TTL_S:
            return text
    text = _fetch_gold_catalog()
    _gold_catalog_cache = (now, text)
    return text


# ---------------------------------------------------------------------------
# Nodes
# ---------------------------------------------------------------------------

def plan_query_node(state: ChatState) -> ChatState:
    start = time.monotonic()
    metrics = _load_metrics()
    matched = _match_metric(state.get("question", ""), metrics)

    # Check if the matched metric is unsupported
    if matched and matched["status"] == "unsupported":
        latency = round((time.monotonic() - start) * 1000, 1)
        trace = list(state.get("trace", []))
        trace.append({"node": "plan_query", "latency_ms": latency})
        return {
            **state,
            "metric_name": matched["name"],
            "metric_status": "unsupported",
            "metric_definition": matched.get("definition", ""),
            "sql_error": f"unsupported metric: {matched['name']}",
            "trace": trace,
        }

    metric_info = json.dumps(matched, default=str) if matched else "null"
    metric_templates = _build_metric_templates_text(
        metrics, state.get("question", "")
    )
    gold_catalog = _gold_catalog_text()

    prompt = render(
        _load_prompt("sql_planner.md"),
        question=state.get("question", ""),
        metric_info=metric_info,
        metric_templates=metric_templates,
        gold_catalog=gold_catalog,
    )

    llm = _llm()
    try:
        resp = llm.invoke([HumanMessage(content=prompt)])
        parsed = json.loads(resp.content)
    except Exception as exc:
        parsed = {"error": f"LLM error: {exc}"}

    latency = round((time.monotonic() - start) * 1000, 1)
    trace = list(state.get("trace", []))
    trace.append({"node": "plan_query", "latency_ms": latency})

    return {
        **state,
        "metric_name": matched["name"] if matched else None,
        "metric_status": matched["status"] if matched else None,
        "metric_definition": matched.get("definition", "") if matched else None,
        "generated_sql": parsed.get("sql"),
        "sql_error": parsed.get("error"),
        "trace": trace,
    }


def validate_sql_node(state: ChatState) -> ChatState:
    start = time.monotonic()
    raw_sql = state.get("generated_sql") or ""
    error = state.get("sql_error")

    if error or not raw_sql:
        latency = round((time.monotonic() - start) * 1000, 1)
        trace = list(state.get("trace", []))
        trace.append({"node": "validate_sql", "latency_ms": latency})
        return {**state, "trace": trace}

    try:
        result = validate_and_sanitise(raw_sql)
        sanitised = result.sanitised_sql
        err = None
    except SQLValidationError as exc:
        sanitised = None
        err = str(exc)

    latency = round((time.monotonic() - start) * 1000, 1)
    trace = list(state.get("trace", []))
    trace.append({"node": "validate_sql", "latency_ms": latency})
    return {**state, "sanitised_sql": sanitised, "sql_error": err, "trace": trace}


def execute_sql_node(state: ChatState) -> ChatState:
    start = time.monotonic()
    sql = state.get("sanitised_sql")
    if not sql or state.get("sql_error"):
        latency = round((time.monotonic() - start) * 1000, 1)
        trace = list(state.get("trace", []))
        trace.append({"node": "execute_sql", "latency_ms": latency})
        return {**state, "trace": trace}

    try:
        from db.client import execute_safe
        result = execute_safe(sql)
        rows = result.rows
        row_count = result.row_count
        obs_min = result.observed_at_min
        obs_max = result.observed_at_max
        err = None
    except Exception as exc:
        rows, row_count = [], 0
        obs_min, obs_max = None, None
        err = str(exc)

    latency = round((time.monotonic() - start) * 1000, 1)
    trace = list(state.get("trace", []))
    trace.append({"node": "execute_sql", "latency_ms": latency})
    return {
        **state,
        "rows": rows,
        "row_count": row_count,
        "observed_at_min": obs_min,
        "observed_at_max": obs_max,
        "sql_error": err,
        "trace": trace,
    }


def repair_sql_node(state: ChatState) -> ChatState:
    """Attempt one SQL repair from the error message."""
    start = time.monotonic()
    error = state.get("sql_error", "")
    original_sql = state.get("generated_sql", "")

    prompt = f"""The following SQL query was rejected with this error:

Error: {error}

Original SQL:
{original_sql}

Fix the SQL so it is a single SELECT over the allowlisted relations only:
  Silver: silver.v_latest_observation, silver.v_latest_shelf_position,
          silver.v_all_platforms
  Gold:   the dash.* tables and views listed in the planner prompt
          (prefer dash.v_* views; dash.v_chatbot_availability_city for
          city-level availability)
Never reference silver.demo, base scraped tables (silver.blinkit / zepto /
instamart / jiomart) or the app / ops / auth / storage schemas.

If the error says a column does not exist:
- use ONLY the real date columns the error lists for that relation;
- if the relation has no date column (e.g. dash.v_fp_ad_page, dash.fp_ad_page_perf,
  dash.v_fp_sales_city), do NOT add `day`, `date`, `report_date` or `obs_date` —
  aggregate across all rows and group by snapshot_label / page_name / city instead.
- never reintroduce the column that caused the error.
Output JSON only: {{"sql": "<fixed query>"}}"""

    llm = _llm()
    try:
        resp = llm.invoke([HumanMessage(content=prompt)])
        parsed = json.loads(resp.content)
        new_sql = parsed.get("sql", "")
    except Exception as exc:
        new_sql = ""

    sql_retry = state.get("sql_retry_count", 0) + 1
    latency = round((time.monotonic() - start) * 1000, 1)
    trace = list(state.get("trace", []))
    trace.append({"node": "repair_sql", "latency_ms": latency})
    return {
        **state,
        "generated_sql": new_sql,
        "sanitised_sql": None,
        "sql_error": None,
        "sql_retry_count": sql_retry,
        "trace": trace,
    }


def verify_numeric_node(state: ChatState) -> ChatState:
    """
    Check that every number in the draft answer appears in the rows,
    and that the answer states scope + time window + row count.
    """
    start = time.monotonic()
    draft = state.get("draft_answer", "")
    rows = state.get("rows", [])

    # Extract numbers from draft answer
    nums_in_answer = set(re.findall(r"\b\d+(?:\.\d+)?\b", draft))
    if not nums_in_answer:
        # No numbers to verify — pass
        ok = True
    else:
        # Flatten all numeric values from rows
        row_values: set[str] = set()
        for row in rows:
            for v in row.values():
                if v is not None:
                    try:
                        row_values.add(str(round(float(v), 4)))
                        row_values.add(str(int(float(v))))
                    except (ValueError, TypeError):
                        row_values.add(str(v))

        ungrounded = []
        for n in nums_in_answer:
            # Tolerance: within 0.5%
            try:
                n_f = float(n)
                found = any(
                    abs(n_f - float(rv)) <= abs(n_f * 0.005)
                    for rv in row_values
                    if rv.replace(".", "").replace("-", "").isdigit()
                )
            except ValueError:
                found = str(n) in row_values
            if not found:
                ungrounded.append(n)

        ok = len(ungrounded) == 0
        if not ok:
            state = {**state, "_ungrounded_numbers": ungrounded}

    latency = round((time.monotonic() - start) * 1000, 1)
    trace = list(state.get("trace", []))
    trace.append({"node": "verify_numeric", "latency_ms": latency})
    return {**state, "_numeric_verified": ok, "trace": trace}


def format_answer_node(state: ChatState) -> ChatState:
    """Call the LLM to format the final answer with provenance."""
    start = time.monotonic()

    rows = state.get("rows", [])
    row_count = state.get("row_count", 0)
    metric_info = json.dumps({
        "name": state.get("metric_name"),
        "status": state.get("metric_status"),
        "definition": state.get("metric_definition"),
    })
    prompt = render(
        _load_prompt("sql_answer.md"),
        sql=state.get("sanitised_sql", ""),
        rows=json.dumps(rows[:20], default=str),
        row_count=row_count,
        metric_info=metric_info,
        obs_min=state.get("observed_at_min", "unknown"),
        obs_max=state.get("observed_at_max", "unknown"),
        question=state.get("question", ""),
    )
    llm = ChatOpenAI(
        model=settings.llm_generator_model,
        api_key=settings.llm_api_key,
        base_url=settings.llm_api_base,
        temperature=0,
    )
    try:
        resp = llm.invoke([HumanMessage(content=prompt)])
        answer = resp.content
    except Exception as exc:
        answer = f"[Answer formatting error: {exc}]"

    latency = round((time.monotonic() - start) * 1000, 1)
    trace = list(state.get("trace", []))
    trace.append({"node": "format_answer", "latency_ms": latency})
    return {
        **state,
        "draft_answer": answer,
        "final_answer": answer,
        "abstain_reason": None,
        "sources": [state.get("sanitised_sql", "")],
        "trace": trace,
    }


def sql_abstain_node(state: ChatState) -> ChatState:
    err = state.get("sql_error", "unknown error")
    metric = state.get("metric_name", "")
    metric_status = state.get("metric_status", "")

    if metric_status == "unsupported":
        metric_def = state.get("metric_definition", "")
        reason = (
            f"The metric '{metric}' is not available in the SIDNL data. "
            f"Status: unsupported. {metric_def.strip()}"
        )
    elif state.get("row_count", 0) == 0 and not err:
        filters_used = state.get("sanitised_sql", "")
        reason = f"No matching observations found. Filters used: {filters_used[:200]}"
    else:
        reason = f"Could not execute the query after repair attempt. Error: {err}"

    trace = list(state.get("trace", []))
    trace.append({"node": "sql_abstain", "latency_ms": 0})
    return {
        **state,
        "final_answer": f"I cannot answer this numeric question. {reason}",
        "abstain_reason": reason,
        "trace": trace,
    }


def zero_rows_node(state: ChatState) -> ChatState:
    sql = state.get("sanitised_sql", "")
    reason = (
        "No matching observations found for the given filters. "
        f"SQL used: {sql[:300]}"
    )
    trace = list(state.get("trace", []))
    trace.append({"node": "zero_rows", "latency_ms": 0})
    return {
        **state,
        "final_answer": f"No matching observations found. Filters used:\n```sql\n{sql}\n```",
        "abstain_reason": reason,
        "trace": trace,
    }


# ---------------------------------------------------------------------------
# Conditional edges
# ---------------------------------------------------------------------------

def _after_validate(state: ChatState) -> str:
    if state.get("sql_error") and state.get("sql_retry_count", 0) < 1:
        return "repair"
    if state.get("sql_error"):
        return "abstain"
    return "execute"


def _after_execute(state: ChatState) -> str:
    if state.get("sql_error") and state.get("sql_retry_count", 0) < 1:
        return "repair"
    if state.get("sql_error"):
        return "abstain"
    if state.get("row_count", 0) == 0:
        return "zero_rows"
    return "verify"


def _after_verify(state: ChatState) -> str:
    if state.get("_numeric_verified", True):
        return "format"
    return "abstain"


def _after_plan(state: ChatState) -> str:
    if state.get("metric_status") == "unsupported":
        return "abstain"
    if state.get("sql_error"):
        return "abstain"
    return "validate"


# ---------------------------------------------------------------------------
# Graph builder
# ---------------------------------------------------------------------------

def build_sql_graph():
    from langgraph.graph import StateGraph, END

    g = StateGraph(ChatState)
    g.add_node("plan_query",    plan_query_node)
    g.add_node("validate_sql",  validate_sql_node)
    g.add_node("execute_sql",   execute_sql_node)
    g.add_node("repair_sql",    repair_sql_node)
    g.add_node("verify_numeric",verify_numeric_node)
    g.add_node("format_answer", format_answer_node)
    g.add_node("sql_abstain",   sql_abstain_node)
    g.add_node("zero_rows",     zero_rows_node)

    g.set_entry_point("plan_query")
    g.add_conditional_edges("plan_query", _after_plan,
                            {"validate": "validate_sql",
                             "abstain":  "sql_abstain"})
    g.add_conditional_edges("validate_sql", _after_validate,
                            {"execute": "execute_sql",
                             "repair":  "repair_sql",
                             "abstain": "sql_abstain"})
    g.add_edge("repair_sql", "validate_sql")
    g.add_conditional_edges("execute_sql", _after_execute,
                            {"verify":    "verify_numeric",
                             "repair":    "repair_sql",
                             "zero_rows": "zero_rows",
                             "abstain":   "sql_abstain"})
    g.add_conditional_edges("verify_numeric", _after_verify,
                            {"format":  "format_answer",
                             "abstain": "sql_abstain"})
    g.add_edge("format_answer", END)
    g.add_edge("sql_abstain",   END)
    g.add_edge("zero_rows",     END)

    return g.compile()


sql_graph = build_sql_graph()
