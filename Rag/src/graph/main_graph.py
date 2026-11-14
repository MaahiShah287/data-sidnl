"""
src/graph/main_graph.py — Top-level LangGraph that routes to sub-graphs.
"""
from __future__ import annotations

import re
import time
from graph.state import ChatState
from graph.router import router_node


# Only genuinely missing data reaches this node. Sales / revenue / SOV / SOH /
# ROAS / clicks / impressions are supported by the Gold (dash) layer and are
# routed to the numeric path, never here.
_UNSUPPORTED_RULES: list[tuple[tuple[str, ...], str]] = [
    (
        ("instamart", "swiggy instamart"),
        "There are no Instamart rows in the Silver or Gold layer, so Instamart "
        "price, stock and visibility cannot be reported.",
    ),
    (
        ("jiomart", "jio mart"),
        "There are no JioMart rows in the Silver or Gold layer, so JioMart "
        "price, stock and visibility cannot be reported.",
    ),
    (
        ("eta", "delivery eta", "delivery time", "delivery minutes"),
        "Delivery ETA is not available. The `delivery_eta_minutes` column exists "
        "in Silver but is NULL in every row, and no Gold table computes it.",
    ),
    (
        ("market share", "market size", "category size", "industry share"),
        "Industry market share / total category size cannot be computed: SIDNL "
        "only observes the tracked quick-commerce shelf and has no category-size "
        "or competitor-revenue input. Share of Shelf (SOH) and Share of Voice "
        "(SOV) ARE available from the Gold layer.",
    ),
]


def unsupported_node(state: ChatState) -> ChatState:
    """Explain what is genuinely missing, point to the metric dictionary."""
    q = state.get("question", "").lower()

    matched_msg = None
    for keywords, message in _UNSUPPORTED_RULES:
        if any(re.search(rf"\b{re.escape(k)}\b", q) for k in keywords):
            matched_msg = message
            break

    if not matched_msg:
        matched_msg = (
            "This metric or data type is not present in the SIDNL data. "
            "See metrics/metric_dictionary.yaml for the full list of supported "
            "metrics and their status (approved / draft / gold / unsupported)."
        )

    answer = (
        f"⛔ This question cannot be answered with the available data.\n\n"
        f"{matched_msg}\n\n"
        "**Available data** spans two layers:\n"
        "- **Silver** — raw, quality-filtered SKU × store readings: price, "
        "availability, discount, ad placement, shelf position.\n"
        "- **Gold (`dash`)** — dashboard KPIs: OSA / listing / stockouts / DOI, "
        "price parity and cross-platform gaps, share of shelf (SOH), share of "
        "voice (SOV), shelf rank, competitor layer, first-party GMV / units / "
        "ASP / growth, ad spend / clicks / impressions / ROAS / ACOS, fill "
        "rate, PO and invoice / pending value, serviceability and data freshness.\n\n"
        "Genuinely unavailable: delivery ETA, Instamart, JioMart, and industry "
        "market share / total category size.\n\n"
        "See `metrics/metric_dictionary.yaml` and `dash.metric_catalog` for the "
        "authoritative metric list."
    )

    trace = list(state.get("trace", []))
    trace.append({"node": "unsupported", "latency_ms": 0})
    return {
        **state,
        "final_answer": answer,
        "abstain_reason": matched_msg,
        "sources": ["metrics/metric_dictionary.yaml"],
        "trace": trace,
    }


def ambiguous_node(state: ChatState) -> ChatState:
    """Ask one clarifying question."""
    q = state.get("question", "").lower()
    platform_hints = ["blinkit", "zepto", "instamart", "jiomart"]
    mentioned = [p for p in platform_hints if p in q]

    if mentioned:
        clarifier = (
            f"I can see you're asking about **{mentioned[0].title()}**. "
            "Could you tell me which metric you'd like to look at?\n\n"
            "For example:\n"
            "- Availability / OSA / listing rate\n"
            "- Price, discount or price parity\n"
            "- Share of shelf (SOH) or share of voice (SOV)\n"
            "- Sales / GMV / units / ASP\n"
            "- Ad spend, clicks, impressions or ROAS\n"
            "- Shelf position / rank\n\n"
            "Also, do you want this for a specific city, brand, category or "
            "date range?\n\n"
            "_Note: Silver covers raw price/stock/shelf readings; Gold covers "
            "dashboard KPIs. There are no Instamart or JioMart rows, and "
            "delivery ETA is not populated._"
        )
    else:
        clarifier = (
            "Your question is a bit broad. Could you tell me:\n\n"
            "1. **Which metric?** (availability/OSA, price, discount, price "
            "parity, SOV/SOH, rank, GMV/units, ad spend/ROAS, fill rate)\n"
            "2. **Which platform?** (Blinkit or Zepto)\n"
            "3. **Any filters?** (city, brand, category, date range)\n\n"
            "Example: \"What was Mr. Munchies' GMV last month?\" or \"What is "
            "our share of shelf on Blinkit in Mumbai?\"\n\n"
            "_Note: there are no Instamart or JioMart rows, and delivery ETA is "
            "not populated._"
        )

    trace = list(state.get("trace", []))
    trace.append({"node": "ambiguous", "latency_ms": 0})
    return {
        **state,
        "final_answer": clarifier,
        "abstain_reason": None,
        "sources": [],
        "trace": trace,
    }


def _route_to_subgraph(state: ChatState) -> str:
    return state.get("route", "AMBIGUOUS")


def build_main_graph():
    from langgraph.graph import StateGraph, END
    from graph.rag_graph import rag_graph
    from graph.sql_graph import sql_graph

    g = StateGraph(ChatState)

    # Nodes
    g.add_node("router",      router_node)
    g.add_node("rag",         rag_graph)
    g.add_node("sql",         sql_graph)
    g.add_node("unsupported", unsupported_node)
    g.add_node("ambiguous",   ambiguous_node)

    # Edges
    g.set_entry_point("router")
    g.add_conditional_edges(
        "router", _route_to_subgraph,
        {
            "NUMERIC":     "sql",
            "DEFINITION":  "rag",
            "UNSUPPORTED": "unsupported",
            "AMBIGUOUS":   "ambiguous",
        },
    )
    g.add_edge("sql",         END)
    g.add_edge("rag",         END)
    g.add_edge("unsupported", END)
    g.add_edge("ambiguous",   END)

    return g.compile()


# Singleton — imported by api/app.py
main_graph = build_main_graph()
