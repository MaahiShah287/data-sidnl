"""
src/graph/state.py — Typed LangGraph state for the SIDNL chatbot.
"""
from __future__ import annotations
from typing import Any, Literal
from typing_extensions import TypedDict


Route = Literal["NUMERIC", "DEFINITION", "UNSUPPORTED", "AMBIGUOUS"]
RelevanceGrade = Literal["relevant", "ambiguous", "irrelevant"]


class ChatState(TypedDict, total=False):
    # Input
    question: str

    # Routing
    route: Route
    router_confidence: float          # 0–1 score from router

    # RAG path
    rewritten_query: str
    retrieved_chunks: list[dict]      # [{text, source, score, bm25_rank, vec_rank}]
    relevance_grade: list[RelevanceGrade]  # per chunk
    draft_answer: str
    claim_support: list[dict]         # [{claim, supported, chunk_id}]
    retry_count: int
    max_retries: int

    # Numeric path
    metric_name: str | None
    metric_status: str | None         # 'approved'|'draft'|'unsupported'|None
    metric_definition: str | None
    generated_sql: str | None
    sanitised_sql: str | None
    sql_error: str | None
    rows: list[dict]
    row_count: int
    observed_at_min: str | None
    observed_at_max: str | None
    sql_retry_count: int

    # Output
    final_answer: str
    abstain_reason: str | None
    sources: list[str]                # chunk ids or SQL view names
    trace: list[dict]                 # [{node, latency_ms}]
    latency_ms: float
