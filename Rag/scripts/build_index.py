"""
scripts/build_index.py
Builds the Chroma index used by src/retrieval/hybrid.py.

Reads rows from the three allowlisted silver views via db.client (read-only),
formats each row as a text "document" with metadata, embeds locally with
Sentence Transformers (intfloat/multilingual-e5-base by default), and writes
everything to the Chroma collection defined in .env
(CHROMA_PERSIST_DIR / CHROMA_COLLECTION_NAME).

Re-running REPLACES the existing collection contents (delete + re-add),
so the index always mirrors what's in the views.

Usage:
    python scripts/build_index.py
"""
from __future__ import annotations

import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "src"))

from config import settings                      # noqa: E402
from db.client import close_pool                 # noqa: E402

ROWS_PER_DOC = 25          # group rows into chunks of N to keep docs readable
EMBED_BATCH = 64           # rows per embedding call
VIEWS = [
    "silver.v_all_platforms",
    "silver.v_latest_observation",
    "silver.v_latest_shelf_position",
]


def to_text(value) -> str:
    """Make any DB value readable inside a document."""
    if value is None:
        return ""
    return str(value)


def rows_to_documents(view: str, rows: list[dict]) -> list[dict]:
    """
    Convert view rows into documents:
    Each doc = ROWS_PER_DOC consecutive rows rendered as 'col: value' lines,
    prefixed with a header naming the view.
    Metadata carries platform/store/source info so retrieval can filter.
    """
    docs: list[dict] = []
    view_name = view.split(".")[-1]

    for start in range(0, len(rows), ROWS_PER_DOC):
        chunk = rows[start:start + ROWS_PER_DOC]
        lines = [f"[view: {view_name}]"]
        for r in chunk:
            pairs = " | ".join(
                f"{k}: {to_text(v)}" for k, v in sorted(r.items()) if v is not None
            )
            lines.append(pairs)
        text = "\n".join(lines)

        # Metadata: use the first row's platform/store as representative
        first = chunk[0]
        meta = {
            # unified schema (source_file/section/doc_type) used by rag_graph
            "source_file": view_name,
            "section": f"rows {start}-{start + len(chunk) - 1}",
            "doc_type": "data_rows",
            # legacy keys kept for backward compatibility / filtering
            "source_view": view_name,
            "platform": to_text(first.get("platform") or first.get("platform_name")),
            "store": to_text(first.get("store_name") or first.get("store_id")),
            "n_rows": len(chunk),
            "row_start": start,
        }
        doc_id = f"{view_name}:{start}"
        docs.append({"id": doc_id, "text": text, "metadata": meta})

    return docs


def collect_all_documents() -> list[dict]:
    """
    Ingestion reads via a direct READ-ONLY connection (get_bulk_conn), NOT
    execute_safe — safe_sql injects LIMIT 200 per query, which would truncate
    the index, and the pooled 10 s statement_timeout is too short for 56k-row
    views. Read-only is still enforced by the server.
    """
    from db.client import get_bulk_conn

    all_docs: list[dict] = []
    with get_bulk_conn() as conn:
        with conn.cursor() as cur:
            for view in VIEWS:
                print(f"Fetching {view} ...")
                cur.execute(f"SELECT * FROM {view}")
                cols = [d.name for d in cur.description]
                rows = [dict(zip(cols, row)) for row in cur.fetchall()]
                print(f"  {len(rows)} rows")
                if rows:
                    docs = rows_to_documents(view, rows)
                    print(f"  -> {len(docs)} documents")
                    all_docs.extend(docs)
    return all_docs


def write_to_chroma(docs: list[dict]) -> None:
    import chromadb
    from chromadb.config import Settings as ChromaSettings
    from sentence_transformers import SentenceTransformer

    client = chromadb.PersistentClient(
        path=settings.chroma_persist_dir,
        settings=ChromaSettings(anonymized_telemetry=False),
    )

    # Fresh ingest: delete existing collection with same name
    try:
        client.delete_collection(settings.chroma_collection_name)
        print(f"Deleted existing collection '{settings.chroma_collection_name}'")
    except Exception:
        pass  # didn't exist yet

    collection = client.get_or_create_collection(
        name=settings.chroma_collection_name,
        metadata={"hnsw:space": "cosine"},
    )

    print(f"Loading embedding model '{settings.embedding_model}' ...")
    model = SentenceTransformer(settings.embedding_model)

    texts = [d["text"] for d in docs]
    print(f"Embedding {len(texts)} documents (batch {EMBED_BATCH}) ...")
    embeddings = model.encode(
        texts, batch_size=EMBED_BATCH, show_progress_bar=True
    ).tolist()

    collection.add(
        ids=[d["id"] for d in docs],
        documents=texts,
        metadatas=[d["metadata"] for d in docs],
        embeddings=embeddings,
    )
    print(f"Wrote {len(docs)} documents to '{settings.chroma_collection_name}' "
          f"at '{settings.chroma_persist_dir}'")

    # Documentation corpus (metric dictionary + docs/*.md) so DEFINITION
    # questions have something to retrieve. Row metadata is already unified.
    from retrieval.docs_index import ingest_docs

    stats = ingest_docs(
        collection,
        settings.metric_dictionary_path,
        settings.docs_dir,
        settings.embedding_model,
        backfill=False,
    )
    print(f"Ingested {stats['docs']} documentation chunks "
          f"(metric dictionary + {settings.docs_dir})")
    print(f"Collection total: {collection.count()} documents")


def main() -> None:
    if not settings.database_url:
        print("ERROR: DATABASE_URL not configured in .env")
        sys.exit(1)
    try:
        docs = collect_all_documents()
        if not docs:
            print("No rows found in views — nothing to index.")
            sys.exit(1)
        write_to_chroma(docs)
    finally:
        close_pool()
    print("Done. Index is ready for use by retrieval.hybrid.")


if __name__ == "__main__":
    main()
