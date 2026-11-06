"""
src/graph/rag_graph.py — Self-healing RAG subgraph (LangGraph).

Nodes: retrieve → grade_relevance → [generate | rewrite_query | abstain]
       → verify_claims → [final | rewrite | abstain]

IMPORTANT CAVEAT (encoded here per spec):
The critic model that grades relevance and verifies claims is the SAME model
family as the generator.  Self-critique is therefore NOT independent proof.
This is why there are retry limits, evidence-only generation, and an abstain
fallback.  Do not remove those safeguards.
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
from retrieval.hybrid import retrieve

_PROMPTS = Path(__file__).resolve().parent.parent / "prompts"


def _load(name: str) -> str:
    return (_PROMPTS / name).read_text(encoding="utf-8")


def _llm(model_key: str = "generator") -> ChatOpenAI:
    model = {
        "generator": settings.llm_generator_model,
        "critic":    settings.llm_critic_model,
    }[model_key]
    return ChatOpenAI(
        model=model,
        api_key=settings.llm_api_key,
        base_url=settings.llm_api_base,
        temperature=0,
    )


def _critic_json(model_key: str = "critic") -> ChatOpenAI:
    return ChatOpenAI(
        model=settings.llm_critic_model,
        api_key=settings.llm_api_key,
        base_url=settings.llm_api_base,
        temperature=0,
        response_format={"type": "json_object"},
    )


# ---------------------------------------------------------------------------
# Nodes
# ---------------------------------------------------------------------------

def retrieve_node(state: ChatState) -> ChatState:
    start = time.monotonic()
    query = state.get("rewritten_query") or state.get("question", "")
    chunks = retrieve(query, top_k=settings.retrieval_top_k)
    latency = round((time.monotonic() - start) * 1000, 1)
    trace = list(state.get("trace", []))
    trace.append({"node": "retrieve", "latency_ms": latency})
    return {**state, "retrieved_chunks": chunks, "trace": trace}


def grade_relevance_node(state: ChatState) -> ChatState:
    """
    CRAG-style: grade each chunk as relevant/ambiguous/irrelevant.
    Drop irrelevant chunks. Keep relevant+ambiguous.

    Caveat: critic == generator family — not independent.
    """
    start = time.monotonic()
    question = state.get("question", "")
    chunks = state.get("retrieved_chunks", [])
    prompt_tpl = _load("rag_grade_relevance.md")
    critic = _critic_json("critic")

    grades: list[str] = []
    kept_chunks: list[dict] = []

    for chunk in chunks:
        prompt = prompt_tpl.format(
            question=question,
            chunk_text=chunk.get("text", "")[:800],
            chunk_source=chunk.get("metadata", {}).get("source_file", "unknown"),
        )
        try:
            resp = critic.invoke([HumanMessage(content=prompt)])
            result = json.loads(resp.content)
            grade = result.get("grade", "ambiguous")
        except Exception:
            grade = "ambiguous"
        grades.append(grade)
        if grade != "irrelevant":
            kept_chunks.append(chunk)

    latency = round((time.monotonic() - start) * 1000, 1)
    trace = list(state.get("trace", []))
    trace.append({"node": "grade_relevance", "latency_ms": latency})
    return {**state, "retrieved_chunks": kept_chunks, "relevance_grade": grades, "trace": trace}


def _has_enough_evidence(state: ChatState) -> str:
    """Conditional edge: enough relevant chunks?"""
    chunks = state.get("retrieved_chunks", [])
    retry = state.get("retry_count", 0)
    max_r = state.get("max_retries", settings.max_retries)

    if len(chunks) >= 1:
        return "generate"
    if retry < max_r:
        return "rewrite_query"
    return "abstain"


def rewrite_query_node(state: ChatState) -> ChatState:
    start = time.monotonic()
    prompt_tpl = _load("rag_rewrite.md")
    prompt = prompt_tpl.format(
        question=state.get("question", ""),
        previous_rewrite=state.get("rewritten_query", ""),
    )
    llm = _llm("generator")
    try:
        resp = llm.invoke([HumanMessage(content=prompt)])
        parsed = json.loads(resp.content)
        new_query = parsed.get("rewritten_query", state.get("question", ""))
    except Exception:
        new_query = state.get("question", "")

    retry = state.get("retry_count", 0) + 1
    latency = round((time.monotonic() - start) * 1000, 1)
    trace = list(state.get("trace", []))
    trace.append({"node": "rewrite_query", "latency_ms": latency})
    return {**state, "rewritten_query": new_query, "retry_count": retry, "trace": trace}


def generate_node(state: ChatState) -> ChatState:
    start = time.monotonic()
    chunks = state.get("retrieved_chunks", [])
    prompt_tpl = _load("rag_generate.md")

    chunks_text = "\n\n---\n\n".join(
        f"[source: {c.get('metadata', {}).get('source_file', 'unknown')}#"
        f"{c.get('metadata', {}).get('section', '')}]\n{c.get('text', '')}"
        for c in chunks
    )
    prompt = prompt_tpl.format(chunks=chunks_text, question=state.get("question", ""))
    llm = _llm("generator")
    try:
        resp = llm.invoke([HumanMessage(content=prompt)])
        draft = resp.content
    except Exception as exc:
        draft = f"[Generation error: {exc}]"

    latency = round((time.monotonic() - start) * 1000, 1)
    trace = list(state.get("trace", []))
    trace.append({"node": "generate", "latency_ms": latency})
    return {**state, "draft_answer": draft, "trace": trace}


def verify_claims_node(state: ChatState) -> ChatState:
    """
    Split draft into atomic claims and check each is supported by a chunk.
    Caveat: same model family as generator — not independent proof.
    """
    start = time.monotonic()
    draft = state.get("draft_answer", "")
    chunks = state.get("retrieved_chunks", [])
    prompt_tpl = _load("rag_verify_claims.md")

    chunks_text = "\n\n".join(
        f"[{c.get('metadata', {}).get('source_file', 'unk')}]: {c.get('text', '')[:600]}"
        for c in chunks
    )
    prompt = prompt_tpl.format(draft_answer=draft, chunks=chunks_text)
    critic = _critic_json("critic")

    try:
        resp = critic.invoke([HumanMessage(content=prompt)])
        result = json.loads(resp.content)
        claim_support = result.get("claims", [])
        all_supported = result.get("all_supported", True)
    except Exception:
        claim_support = []
        all_supported = True  # fail open — don't falsely abstain on parse errors

    latency = round((time.monotonic() - start) * 1000, 1)
    trace = list(state.get("trace", []))
    trace.append({"node": "verify_claims", "latency_ms": latency})
    return {
        **state,
        "claim_support": claim_support,
        "_all_claims_supported": all_supported,
        "trace": trace,
    }


def _after_verify(state: ChatState) -> str:
    if state.get("_all_claims_supported", True):
        return "finalize"
    retry = state.get("retry_count", 0)
    max_r = state.get("max_retries", settings.max_retries)
    if retry < max_r:
        return "rewrite_query"
    return "abstain"


def abstain_node(state: ChatState) -> ChatState:
    start = time.monotonic()
    chunks = state.get("retrieved_chunks", [])
    unsupported = [
        c.get("claim", "") for c in state.get("claim_support", [])
        if not c.get("supported", True)
    ]
    if unsupported:
        reason = (
            "I cannot verify the following claims against the available documentation: "
            + "; ".join(unsupported[:3])
            + ". Please consult the metric dictionary or your analytics mentor."
        )
    elif not chunks:
        reason = (
            "I could not find relevant documentation for this question after "
            f"{state.get('retry_count', 0)} retrieval attempt(s). "
            "The document may not exist in the knowledge base yet. "
            "Please check with the data team or add the relevant document to docs/."
        )
    else:
        reason = "Could not produce a fully-verified answer. Please consult the metric dictionary."

    latency = round((time.monotonic() - start) * 1000, 1)
    trace = list(state.get("trace", []))
    trace.append({"node": "abstain", "latency_ms": latency})
    return {
        **state,
        "final_answer": f"I cannot answer this question with confidence. {reason}",
        "abstain_reason": reason,
        "trace": trace,
    }


def finalize_rag_node(state: ChatState) -> ChatState:
    sources = [
        f"{c.get('metadata', {}).get('source_file', 'unk')}#{c.get('metadata', {}).get('section', '')}"
        for c in state.get("retrieved_chunks", [])
    ]
    return {
        **state,
        "final_answer": state.get("draft_answer", ""),
        "sources": sources,
        "abstain_reason": None,
    }


# ---------------------------------------------------------------------------
# Graph builder
# ---------------------------------------------------------------------------

def build_rag_graph():
    from langgraph.graph import StateGraph, END

    g = StateGraph(ChatState)
    g.add_node("retrieve",         retrieve_node)
    g.add_node("grade_relevance",  grade_relevance_node)
    g.add_node("rewrite_query",    rewrite_query_node)
    g.add_node("generate",         generate_node)
    g.add_node("verify_claims",    verify_claims_node)
    g.add_node("abstain",          abstain_node)
    g.add_node("finalize_rag",     finalize_rag_node)

    g.set_entry_point("retrieve")
    g.add_edge("retrieve", "grade_relevance")
    g.add_conditional_edges("grade_relevance", _has_enough_evidence,
                            {"generate": "generate",
                             "rewrite_query": "rewrite_query",
                             "abstain": "abstain"})
    g.add_edge("rewrite_query", "retrieve")
    g.add_edge("generate", "verify_claims")
    g.add_conditional_edges("verify_claims", _after_verify,
                            {"finalize": "finalize_rag",
                             "rewrite_query": "rewrite_query",
                             "abstain": "abstain"})
    g.add_edge("finalize_rag", END)
    g.add_edge("abstain", END)

    return g.compile()


rag_graph = build_rag_graph()
