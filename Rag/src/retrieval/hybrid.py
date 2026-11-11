"""
src/retrieval/hybrid.py — Hybrid retrieval: Chroma (vector) + BM25 + RRF fusion.
"""
from __future__ import annotations

import hashlib
import math
from pathlib import Path
from typing import Any

from config import settings

# Lazy imports — these are heavy, only loaded when retrieval is called
_chroma_client = None
_collection = None
_bm25_index = None
_bm25_corpus: list[dict] = []   # [{id, text, metadata}]
_embedder = None


def _get_collection():
    global _chroma_client, _collection
    if _collection is None:
        import chromadb
        from chromadb.config import Settings as ChromaSettings
        _chroma_client = chromadb.PersistentClient(
            path=settings.chroma_persist_dir,
            settings=ChromaSettings(anonymized_telemetry=False),
        )
        _collection = _chroma_client.get_or_create_collection(
            name=settings.chroma_collection_name,
            metadata={"hnsw:space": "cosine"},
        )
    return _collection


def _get_embedder():
    """Load the sentence-transformers model once, not on every query."""
    global _embedder
    if _embedder is None:
        from sentence_transformers import SentenceTransformer
        _embedder = SentenceTransformer(settings.embedding_model)
    return _embedder


def _get_bm25():
    global _bm25_index, _bm25_corpus
    if _bm25_index is None:
        try:
            coll = _get_collection()
            result = coll.get(include=["documents", "metadatas"])
            _bm25_corpus = [
                {"id": id_, "text": doc, "metadata": meta}
                for id_, doc, meta in zip(
                    result["ids"], result["documents"], result["metadatas"]
                )
            ]
        except Exception:
            _bm25_corpus = []

        if _bm25_corpus:
            from rank_bm25 import BM25Okapi
            tokenised = [d["text"].lower().split() for d in _bm25_corpus]
            _bm25_index = BM25Okapi(tokenised)
        else:
            _bm25_index = None
    return _bm25_index, _bm25_corpus


def _rrf_merge(
    vec_results: list[dict],
    bm25_results: list[dict],
    k: int = 60,
) -> list[dict]:
    """Reciprocal Rank Fusion."""
    scores: dict[str, float] = {}
    meta: dict[str, dict] = {}

    for rank, item in enumerate(vec_results):
        id_ = item["id"]
        scores[id_] = scores.get(id_, 0.0) + 1.0 / (rank + k)
        meta[id_] = item

    for rank, item in enumerate(bm25_results):
        id_ = item["id"]
        scores[id_] = scores.get(id_, 0.0) + 1.0 / (rank + k)
        if id_ not in meta:
            meta[id_] = item
        meta[id_]["bm25_rank"] = rank + 1

    merged = sorted(meta.values(), key=lambda x: scores[x["id"]], reverse=True)
    for i, item in enumerate(merged):
        item["rrf_rank"] = i + 1
        item["rrf_score"] = scores[item["id"]]
    return merged


def retrieve(
    query: str,
    top_k: int | None = None,
    doc_types: list[str] | None = None,
) -> list[dict]:
    """
    Hybrid retrieval: Chroma vector search + BM25, fused with RRF.
    Returns top_k chunks sorted by RRF score.
    If the index is empty, returns [].

    doc_types restricts both searches to those metadata doc_type values.
    The RAG path answers DEFINITION questions, so it passes
    ["metric", "documentation"]; otherwise 3,813 data-row chunks crowd the
    32 documentation chunks out of the fused top-k.
    """
    k = top_k or settings.retrieval_top_k
    where = {"doc_type": {"$in": doc_types}} if doc_types else None

    # --- Vector search ---
    coll = _get_collection()
    vec_results: list[dict] = []
    try:
        model = _get_embedder()
        query_embedding = model.encode(query).tolist()
        qr = coll.query(
            query_embeddings=[query_embedding],
            n_results=min(k, coll.count() or 1),
            include=["documents", "metadatas", "distances"],
            **({"where": where} if where else {}),
        )
        for id_, doc, meta, dist in zip(
            qr["ids"][0], qr["documents"][0], qr["metadatas"][0], qr["distances"][0]
        ):
            vec_results.append({"id": id_, "text": doc, "metadata": meta, "vec_distance": dist})
    except Exception:
        pass  # collection empty or model unavailable

    # --- BM25 search ---
    bm25_results: list[dict] = []
    bm25_idx, corpus = _get_bm25()
    if bm25_idx and corpus:
        candidates = [
            (i, d) for i, d in enumerate(corpus)
            if not doc_types or (d.get("metadata") or {}).get("doc_type") in doc_types
        ]
        if candidates:
            scores = bm25_idx.get_scores(query.lower().split())
            ranked = sorted(candidates, key=lambda x: scores[x[0]], reverse=True)[:k]
            for rank_i, (corpus_i, item) in enumerate(ranked):
                item = dict(item)
                item["bm25_score"] = float(scores[corpus_i])
                item["bm25_rank"] = rank_i + 1
                bm25_results.append(item)

    if not vec_results and not bm25_results:
        return []

    merged = _rrf_merge(vec_results, bm25_results)
    return merged[:k]


def reset_index_cache() -> None:
    """Force re-loading the BM25 index on next call (call after ingestion)."""
    global _bm25_index, _bm25_corpus, _collection
    _bm25_index = None
    _bm25_corpus = []
    _collection = None
