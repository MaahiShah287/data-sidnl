"""
src/graph/main_graph.py — Top-level LangGraph that routes to sub-graphs.
"""
from __future__ import annotations

import time
from graph.state import ChatState
from graph.router import router_node


def unsupported_node(state: ChatState) -> ChatState:
    """Explain what data is missing, point to the metric dictionary."""
    q = state.get("question", "").lower()
    # Map keywords to helpful messages
    messages = {
        "sov":  "Share of Voice (SOV) is not yet defined by the company. Status: pending.",
        "soh":  "Share of Shelf (SOH) is not yet defined by the company. Status: pending.",
        "sales": "Sales data is not available in the SIDNL silver layer.",
        "revenue": "Revenue data is not available in the SIDNL silver layer.",
        "ad spend": "Ad spend data is not available in the SIDNL silver layer.",
        "roas": "ROAS requires both ad spend and sales, neither of which is in the data.",
        "conversion": "Conversion data is not available.",
        "clicks": "Click data is not available in the SIDNL silver layer.",
        "impressions": "Impression data is not available in the SIDNL silver layer.",
        "cross-platform price": (
            "Cross-platform price comparison requires a product-matching layer "
            "that is not yet built. I can show per-platform prices if you name a specific product."
        ),
    }
    matched_msg = next(
        (msg for kw, msg in messages.items() if kw in q), None
    )
    if not matched_msg:
        matched_msg = (
            "This metric or data type is not available in the SIDNL silver layer. "
            "See metrics/metric_dictionary.yaml for the full list of supported metrics "
            "and their status (approved / draft / unsupported)."
        )

    answer = (
        f"⛔ This question cannot be answered with the available data.\n\n"
        f"{matched_msg}\n\n"
        "**Available data**: price, availability, discount, ad placement, shelf "
        "position and organic position. Coverage is **Blinkit** (price/stock: "
        "brand Mr. Munchies only; shelf: Amul + Mr. Munchies) and **Zepto shelf "
        "position for Mumbai only**. There are no Instamart or JioMart rows.\n\n"
        "For SOV/SOH: check with your analytics lead for the company definition."
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
            "- Availability / in-stock rate\n"
            "- Price or discounts\n"
            "- Ad placement rate\n"
            "- Shelf position / organic position\n"
            "- Delivery ETA\n\n"
            "Also, do you want this for a specific city, brand, or category?"
        )
    else:
        clarifier = (
            "Your question is a bit broad. Could you tell me:\n\n"
            "1. **Which platform?** (Blinkit, Zepto, Instamart, JioMart)\n"
            "2. **Which metric?** (price, availability, discount, ad placement, position)\n"
            "3. **Any filters?** (city, brand, category, time range)\n\n"
            "Example: \"What is the in-stock rate for brand X on Blinkit in Mumbai?\""
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
