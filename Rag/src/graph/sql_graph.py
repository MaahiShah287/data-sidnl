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


def _match_metric(question: str, metrics: list[dict]) -> dict | None:
    """Simple keyword match against metric names and definition text."""
    q_lower = question.lower()
    best = None
    for m in metrics:
        name_match = m["name"].lower().replace("_", " ") in q_lower
        if name_match:
            best = m
            break
    return best


def _build_metric_templates_text(metrics: list[dict]) -> str:
    approved_draft = [m for m in metrics if m["status"] in ("approved", "draft")]
    lines = []
    for m in approved_draft:
        lines.append(f"-- Metric: {m['name']} [{m['status']}]")
        lines.append(f"-- Definition: {m['definition'].strip()}")
        if m.get("sql_template"):
            lines.append(m["sql_template"].strip()[:400])
        lines.append("")
    return "\n".join(lines) if lines else "(none)"


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
    metric_templates = _build_metric_templates_text(metrics)

    prompt = render(
        _load_prompt("sql_planner.md"),
        question=state.get("question", ""),
        metric_info=metric_info,
        metric_templates=metric_templates,
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

Fix the SQL so it only uses SELECT on silver.v_latest_observation,
silver.v_latest_shelf_position, or silver.v_all_platforms.
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
