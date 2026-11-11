"""
scripts/add_docs.py

Append the documentation corpus (metric dictionary + curated markdown) to an
EXISTING Chroma collection, without re-embedding the 3,813 data-row documents.

Also backfills the unified metadata schema (source_file / section / doc_type)
on the existing row documents, so citations stop rendering as "unknown#".

Safe to run repeatedly: doc chunks are replaced, row documents are only
touched when their metadata lacks `doc_type`.

Usage:
    python scripts/add_docs.py
"""
from __future__ import annotations

import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "src"))

from config import settings                              # noqa: E402
from retrieval.docs_index import ingest_docs, curated_docs, all_doc_chunks  # noqa: E402


def main() -> int:
    import chromadb
    from chromadb.config import Settings as ChromaSettings

    docs = all_doc_chunks(settings.metric_dictionary_path, settings.docs_dir)
    if not docs:
        print("WARNING: no documentation found to ingest.")
        print(f"  metric dictionary: {settings.metric_dictionary_path}")
        print(f"  docs dir         : {settings.docs_dir}")
        print("  (check METRIC_DICTIONARY_PATH / DOCS_DIR)")
        return 1

    print(f"Documentation chunks: {len(docs)}")
    print(f"  docs files: {[p.name for p in curated_docs(settings.docs_dir)]}")

    client = chromadb.PersistentClient(
        path=settings.chroma_persist_dir,
        settings=ChromaSettings(anonymized_telemetry=False),
    )
    collection = client.get_or_create_collection(
        name=settings.chroma_collection_name,
        metadata={"hnsw:space": "cosine"},
    )

    before = collection.count()
    print(f"Collection '{settings.chroma_collection_name}' currently has {before} documents.")

    stats = ingest_docs(
        collection,
        settings.metric_dictionary_path,
        settings.docs_dir,
        settings.embedding_model,
    )

    after = collection.count()
    print(
        f"Backfilled metadata on {stats['backfilled']} row documents; "
        f"upserted {stats['docs']} doc chunks."
    )
    print(f"Collection now has {after} documents (was {before}).")
    print("Done. Restart the API/process so the BM25 cache picks up new docs.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
