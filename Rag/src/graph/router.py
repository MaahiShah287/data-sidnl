"""
src/graph/router.py — LangGraph router node.
Classifies the user's question into NUMERIC | DEFINITION | UNSUPPORTED | AMBIGUOUS.
"""
from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any

from langchain_openai import ChatOpenAI
from langchain_core.messages import SystemMessage, HumanMessage

from config import settings
from graph.state import ChatState

_PROMPT_PATH = Path(__file__).resolve().parent.parent / "prompts" / "router_system.md"
_ROUTER_PROMPT = _PROMPT_PATH.read_text(encoding="utf-8")

# Hard-coded pattern overrides (belt-and-suspenders before the LLM call).
# Only data that is GENUINELY absent may short-circuit to UNSUPPORTED. Gold
# KPIs (sales, GMV, SOV, SOH, ROAS, clicks, impressions, …) are supported and
# must go through the normal NUMERIC path.
_UNSUPPORTED_PATTERNS: list[tuple[re.Pattern, str]] = [
    (re.compile(r"\binstamart\b"), "instamart"),
    (re.compile(r"\bjio\s*mart\b"), "jiomart"),
    (
        re.compile(r"\bdelivery\s*(?:eta|time|minutes?)\b|\beta\b"),
        "delivery ETA",
    ),
    (
        re.compile(
            r"\b(?:industry|total)\s+market\s+(?:share|size)\b"
            r"|\bmarket\s+size\b|\bcategory\s+size\b"
        ),
        "industry market share",
    ),
]

# Prompt-injection / write attempts. These are matched against the QUESTION,
# before any LLM call, so a hostile or confused prompt can never reach the
# planner. Patterns are statement-shaped on purpose: ordinary prose such as
# "update me on GMV" or "how do I delete a filter" must not be blocked.
# safe_sql.py remains the hard guarantee; this is the cheap first line.
_INJECTION_PATTERNS: list[tuple[re.Pattern, str]] = [
    (
        re.compile(r"\b(?:drop|truncate)\s+(?:table|view|schema|database|index|role|user)\b"),
        "a DROP/TRUNCATE statement",
    ),
    (
        re.compile(
            r"\bdelete\s+(?:all\s+|the\s+|any\s+)*(?:from\b"
            r"|(?:rows?|records?|data|entries|observations?|everything)\b)"
        ),
        "a DELETE statement",
    ),
    (re.compile(r"\binsert\s+into\b"), "an INSERT statement"),
    (
        re.compile(r"\bupdate\s+[a-z_][\w.]*\s+set\b"),
        "an UPDATE statement",
    ),
    (
        re.compile(r"\balter\s+(?:table|view|schema|database|index|role|user)\b"),
        "an ALTER statement",
    ),
    (
        re.compile(r"\bgrant\s+(?:select|insert|update|delete|all|usage|connect)\b"),
        "a GRANT statement",
    ),
    (
        re.compile(r"\bcreate\s+(?:table|view|schema|database|index|role|user|function)\b"),
        "a CREATE statement",
    ),
    (re.compile(r"\brevoke\s+\w+\s+on\b"), "a REVOKE statement"),
    (
        re.compile(r"\bcopy\s+[\w.\"]+\s+(?:from|to)\b"),
        "a COPY statement",
    ),
    (re.compile(r"\bexec\s+[a-z_][\w.]*"), "an EXEC statement"),
    (re.compile(r"\bexecute\s*\(|\bexecute\s+[a-z_][\w.]*\s*\("), "an EXECUTE statement"),
    (re.compile(r"\bcall\s+[a-z_][\w.]*\s*\("), "a CALL statement"),
    (re.compile(r"\bset\s+role\b"), "a SET ROLE statement"),
]

# Schemas the chatbot must never read. Matching requires an identifier after
# the dot (so "the app. It ..." in normal prose does not trip the guard).
_UNAUTHORIZED_SCHEMA_RE = re.compile(
    r"\b(?:auth|ops|app|storage|pg_catalog|information_schema)\.[a-z_][\w$]*"
    r"|\bsilver\.demo\b",
    re.IGNORECASE,
)


def detect_injection(question: str) -> str | None:
    """
    Return a short label when the question is a SQL write/DDL statement or a
    probe of an unauthorized schema; otherwise ``None``.

    Used by both the router (to short-circuit to UNSUPPORTED before the LLM)
    and the unsupported node (to explain *why* it refused).
    """
    lowered = question.lower()
    for pattern, label in _INJECTION_PATTERNS:
        if pattern.search(lowered):
            return label
    if _UNAUTHORIZED_SCHEMA_RE.search(question):
        return "a reference to an unauthorized schema"
    return None


# Bare "what is <brand/platform>?" questions are documentation questions. Keep
# this narrow: "What is Amul's price?" must still go to NUMERIC.
_ENTITY_DEFINITION_RE = re.compile(
    r"^\s*(?:what|who)\s+(?:is|are)\s+"
    r"(?:mr\.?\s+munchies|amul|sidnl|blinkit|zepto)"
    r"\s*\?*\s*$",
    re.IGNORECASE,
)

# If a question names a metric, "tell me about X" is answerable, not vague.
_METRIC_HINTS = {
    "sales", "revenue", "gmv", "units", "asp", "osa", "availability",
    "listing", "stockout", "soh", "share of shelf", "sov", "share of voice",
    "discount", "price", "mrp", "selling price", "sale price", "parity",
    "roas", "ad spend", "clicks", "impressions", "ctr", "cpc", "cpm", "cvr",
    "conversion", "fill rate", "serviceab", "invoice", "pending", "stock",
    "in stock", "available", "inventory", "rank", "shelf position",
    "sponsored", "freshness", "doi",
}

# Silver price/stock/shelf questions are NUMERIC, but the router LLM sometimes
# labels them UNSUPPORTED because the metric dictionary has no "price" KPI
# (price lives in Silver, not in the Gold catalog). This deterministic guard
# rescues them, without ever overriding a genuinely absent data source
# (Instamart/JioMart/ETA/market size) or a write attempt.
_SILVER_METRIC_RE = re.compile(
    r"\b(?:price|prices|pricing|mrp|sale\s+price|selling\s+price|"
    r"discount|stock|in\s*stock|out\s+of\s+stock|stockout|availability|"
    r"available|inventory|shelf\s+(?:position|rank)|sponsored|ad\s+placement)\b",
    re.IGNORECASE,
)
_TRACKED_ENTITY_RE = re.compile(
    r"\b(?:mr\.?\s+munchies|amul|mother\s+dairy|sidnl|blinkit|zepto)\b",
    re.IGNORECASE,
)
# Do not turn a "what does X mean / what is the strategy" question into SQL.
_DEFINITION_HINT_RE = re.compile(
    r"\b(?:meaning|definition|define|strategy|calculated|formula|"
    r"what\s+does\b|how\s+is\b.*\b(?:calculated|defined))\b",
    re.IGNORECASE,
)

_CLARIFY_TRIGGERS = {
    "how is it doing", "how are they doing", "tell me about",
    "show me data", "give me information",
}


def _build_llm() -> ChatOpenAI:
    return ChatOpenAI(
        model=settings.llm_router_model,
        api_key=settings.llm_api_key,
        base_url=settings.llm_api_base,
        temperature=0,
        response_format={"type": "json_object"},
    )


def _keyword_override(question: str) -> dict | None:
    q_lower = question.lower()

    injection = detect_injection(question)
    if injection:
        return {
            "route": "UNSUPPORTED",
            "confidence": 0.99,
            "reason": (
                f"Question contains {injection}. The chatbot is read-only and "
                "can only run SELECTs over the curated Silver views and Gold "
                "(dash) tables."
            ),
            "detected_language": _detect_lang(question),
        }

    if _ENTITY_DEFINITION_RE.match(question):
        return {
            "route": "DEFINITION",
            "confidence": 0.95,
            "reason": (
                "Question asks what a tracked brand, platform or SIDNL itself "
                "is; answered from the documentation corpus."
            ),
            "detected_language": _detect_lang(question),
        }

    for pattern, label in _UNSUPPORTED_PATTERNS:
        if pattern.search(q_lower):
            return {
                "route": "UNSUPPORTED",
                "confidence": 0.99,
                "reason": f"Question asks for {label}, which is not in Silver or Gold.",
                "detected_language": _detect_lang(question),
            }

    names_metric = any(hint in q_lower for hint in _METRIC_HINTS)
    if not names_metric:
        for trigger in _CLARIFY_TRIGGERS:
            if trigger in q_lower:
                return {
                    "route": "AMBIGUOUS",
                    "confidence": 0.9,
                    "reason": "Question is too vague; a clarifying question is needed.",
                    "detected_language": _detect_lang(question),
                }
    return None


def _silver_numeric_override(question: str, route: str) -> dict | None:
    """
    Rescue a Silver price/stock/shelf question that the router LLM mislabelled.

    Fires only when the question names both a Silver metric (price, MRP,
    discount, stock, availability, shelf position) and a tracked brand or
    platform, and never for a genuine UNSUPPORTED case (Instamart, JioMart,
    delivery ETA, industry market size), a write attempt, or a
    meaning/definition question.
    """
    if route == "NUMERIC":
        return None
    if detect_injection(question):
        return None
    if _DEFINITION_HINT_RE.search(question):
        return None
    q_lower = question.lower()
    for pattern, _ in _UNSUPPORTED_PATTERNS:
        if pattern.search(q_lower):
            return None
    if not (_SILVER_METRIC_RE.search(question) and _TRACKED_ENTITY_RE.search(question)):
        return None
    return {
        "route": "NUMERIC",
        "confidence": 0.9,
        "reason": (
            "Question asks for a Silver price/stock/shelf metric for a tracked "
            "brand or platform; answered from silver.v_all_platforms."
        ),
        "detected_language": _detect_lang(question),
    }


def _detect_lang(text: str) -> str:
    """Heuristic: check for Devanagari script or common Hinglish markers."""
    if any("\u0900" <= ch <= "\u097f" for ch in text):
        return "hindi"
    hinglish_words = {"kya", "hai", "mein", "ka", "ki", "ke", "bata",
                      "kaise", "kitna", "kitni", "aur", "nahi", "hain"}
    words = set(text.lower().split())
    if words & hinglish_words:
        return "hinglish"
    return "english"


def router_node(state: ChatState) -> ChatState:
    """LangGraph node: classify the question and populate state['route']."""
    start = time.monotonic()
    question = state.get("question", "")

    # 1. Keyword override (fast path)
    override = _keyword_override(question)
    router_error = None
    if override:
        result = override
    else:
        # 2. LLM classification
        llm = _build_llm()
        messages = [
            SystemMessage(content=_ROUTER_PROMPT),
            HumanMessage(content=question),
        ]
        try:
            response = llm.invoke(messages)
            result = json.loads(response.content)
            rescue = _silver_numeric_override(question, result.get("route", ""))
            if rescue:
                result = rescue
        except Exception as exc:
            # Fail safe: route to AMBIGUOUS so the user gets a clarifying question
            router_error = f"{type(exc).__name__}: {exc}"
            result = {
                "route": "AMBIGUOUS",
                "confidence": 0.0,
                "reason": f"Router LLM error: {exc}",
                "detected_language": _detect_lang(question),
            }

    latency = round((time.monotonic() - start) * 1000, 1)
    trace = list(state.get("trace", []))
    trace.append({"node": "router", "latency_ms": latency})

    return {
        **state,
        "route": result.get("route", "AMBIGUOUS"),
        "router_confidence": result.get("confidence", 0.0),
        "router_error": router_error,
        "trace": trace,
        # Store detected language for later use
        "_detected_language": result.get("detected_language", "english"),
    }
