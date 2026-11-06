"""
src/api/app.py — FastAPI /chat and /health endpoints for the SIDNL chatbot.

Response shape (every route):
{
  "answer": str,
  "route": str,
  "abstain_reason": str | null,
  "sql": str | null,
  "rows": list[dict],
  "sources": list[str],
  "retry_count": int,
  "metric_status": str | null,
  "latency_ms": float,
  "trace": [{node: str, latency_ms: float}]
}
"""
from __future__ import annotations

import time
from typing import Any

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config import settings

app = FastAPI(title="SIDNL Chatbot API", version="0.1.0")

# CORS — open for local development; tighten in production
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


class ChatRequest(BaseModel):
    question: str


class ChatResponse(BaseModel):
    answer: str
    route: str | None = None
    abstain_reason: str | None = None
    sql: str | None = None
    rows: list[dict] = []
    sources: list[str] = []
    retry_count: int = 0
    metric_status: str | None = None
    latency_ms: float = 0.0
    trace: list[dict] = []


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/chat", response_model=ChatResponse)
def chat(req: ChatRequest):
    if not req.question or not req.question.strip():
        raise HTTPException(status_code=400, detail="question must not be empty")

    wall_start = time.monotonic()

    # Lazy import of graph (heavy — sentence transformers, etc.)
    try:
        from graph.main_graph import main_graph
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"Graph not available: {exc}")

    initial_state = {
        "question": req.question.strip(),
        "retry_count": 0,
        "sql_retry_count": 0,
        "max_retries": settings.max_retries,
        "trace": [],
        "rows": [],
        "sources": [],
    }

    try:
        final_state = main_graph.invoke(initial_state)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Graph execution error: {exc}")

    total_ms = round((time.monotonic() - wall_start) * 1000, 1)

    return ChatResponse(
        answer=final_state.get("final_answer", ""),
        route=final_state.get("route"),
        abstain_reason=final_state.get("abstain_reason"),
        sql=final_state.get("sanitised_sql"),
        rows=final_state.get("rows", []),
        sources=final_state.get("sources", []),
        retry_count=final_state.get("retry_count", 0),
        metric_status=final_state.get("metric_status"),
        latency_ms=total_ms,
        trace=final_state.get("trace", []),
    )
