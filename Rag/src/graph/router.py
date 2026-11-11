"""
src/graph/router.py — LangGraph router node.
Classifies the user's question into NUMERIC | DEFINITION | UNSUPPORTED | AMBIGUOUS.
"""
from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from langchain_openai import ChatOpenAI
from langchain_core.messages import SystemMessage, HumanMessage

from config import settings
from graph.state import ChatState

_PROMPT_PATH = Path(__file__).resolve().parent.parent / "prompts" / "router_system.md"
_ROUTER_PROMPT = _PROMPT_PATH.read_text(encoding="utf-8")

# Hard-coded pattern overrides (belt-and-suspenders before the LLM call)
_UNSUPPORTED_KEYWORDS = {
    "sales", "revenue", "units sold", "ad spend", "roas", "conversion",
    "clicks", "impressions", "ctr", "sov", "share of voice",
    "soh", "share of shelf",
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
    for kw in _UNSUPPORTED_KEYWORDS:
        if kw in q_lower:
            return {
                "route": "UNSUPPORTED",
                "confidence": 0.99,
                "reason": f"Question mentions '{kw}' which is not in the SIDNL data.",
                "detected_language": _detect_lang(question),
            }
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
