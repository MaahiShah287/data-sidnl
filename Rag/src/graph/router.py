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

# If a question names a metric, "tell me about X" is answerable, not vague.
_METRIC_HINTS = {
    "sales", "revenue", "gmv", "units", "asp", "osa", "availability",
    "listing", "stockout", "soh", "share of shelf", "sov", "share of voice",
    "discount", "price", "parity", "roas", "ad spend", "clicks",
    "impressions", "ctr", "cpc", "cpm", "cvr", "conversion", "fill rate",
    "serviceab", "invoice", "pending", "stock", "inventory", "rank",
    "freshness", "doi",
}

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
