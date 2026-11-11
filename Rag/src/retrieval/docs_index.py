"""
src/retrieval/docs_index.py — Documentation corpus for the RAG path.

The row documents built by scripts/build_index.py answer "what does the data
look like"; they do not answer "what does this metric mean". DEFINITION
questions need real documentation, so this module turns:

  * metrics/metric_dictionary.yaml  -> one document per metric
  * markdown under docs/            -> one document per heading

into Chroma chunks with a stable metadata schema:

  source_file : human-readable origin (e.g. "docs/ARCHITECTURE.md")
  section     : heading / metric name
  doc_type    : "metric" | "documentation" | "data_rows"

ingest_docs() is append-only: it backfills metadata on the existing row
documents (no re-embedding) and upserts the documentation chunks. That means
adding docs does NOT require the ~45-50 minute row rebuild.
"""
from __future__ import annotations

import hashlib
import re
from pathlib import Path

MAX_CHARS = 1400
OVERLAP = 200
EMBED_BATCH = 32

# Audit/report/erd files are noise for retrieval: they describe past incidents
# and are not stable answers to metric questions.
_SKIP_PATTERNS = re.compile(
    r"(audit|report|completion|optimization|erd|changelog|history)", re.IGNORECASE
)


# ---------------------------------------------------------------------------
# Chunking
# ---------------------------------------------------------------------------

def _split_long(text: str, max_chars: int = MAX_CHARS, overlap: int = OVERLAP) -> list[str]:
    """Split text on paragraph boundaries, with a small overlap between chunks."""
    text = text.strip()
    if not text:
        return []
    if len(text) <= max_chars:
        return [text]

    paragraphs = re.split(r"\n\s*\n", text)
    chunks: list[str] = []
    current = ""

    for para in paragraphs:
        para = para.strip()
        if not para:
            continue
        if not current:
            current = para
        elif len(current) + len(para) + 2 <= max_chars:
            current += "\n\n" + para
        else:
            chunks.append(current)
            tail = current[-overlap:] if overlap else ""
            current = (tail + "\n\n" + para).strip() if tail else para

    if current:
        chunks.append(current)
    return chunks


def _doc_id(source_file: str, section: str, part: int) -> str:
    key = f"{source_file}|{section}|{part}".encode()
    return "doc:" + hashlib.sha1(key).hexdigest()[:16]


def chunk_markdown(text: str, source_file: str, doc_type: str = "documentation") -> list[dict]:
    """Split a markdown document into heading-scoped chunks."""
    heading = "Introduction"
    buf: list[str] = []
    sections: list[tuple[str, str]] = []
    in_fence = False

    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            buf.append(line)
            continue

        match = None if in_fence else re.match(r"^(#{1,6})\s+(.*)$", line)
        if match:
            body = "\n".join(buf).strip()
            if body:
                sections.append((heading, body))
            heading = match.group(2).strip()
            buf = []
        else:
            buf.append(line)

    body = "\n".join(buf).strip()
    if body:
        sections.append((heading, body))

    docs: list[dict] = []
    for section, section_body in sections:
        if not section_body:
            continue
        for part, piece in enumerate(_split_long(section_body)):
            label = section if part == 0 else f"{section} (part {part + 1})"
            docs.append(
                {
                    "id": _doc_id(source_file, section, part),
                    "text": f"[{source_file} — {section}]\n{piece}",
                    "metadata": {
                        "source_file": source_file,
                        "section": label,
                        "doc_type": doc_type,
                    },
                }
            )
    return docs


# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------

def metric_documents(metric_dict_path: str | Path) -> list[dict]:
    """One retrievable document per metric in the metric dictionary."""
    import yaml

    path = Path(metric_dict_path)
    if not path.exists():
        return []

    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    docs: list[dict] = []

    for metric in data.get("metrics", []):
        name = str(metric.get("name", "")).strip()
        if not name:
            continue

        lines = [f"Metric: {name}", f"Status: {metric.get('status', 'unknown')}"]
        if metric.get("source_view"):
            lines.append(f"Source view: {metric['source_view']}")
        if metric.get("grain"):
            lines.append(f"Grain: {metric['grain']}")
        definition = str(metric.get("definition", "")).strip()
        if definition:
            lines.append(f"Definition:\n{definition}")
        open_questions = metric.get("open_questions") or []
        if open_questions:
            lines.append("Open questions:\n" + "\n".join(f"- {q}" for q in open_questions))

        docs.append(
            {
                "id": _doc_id("metrics/metric_dictionary.yaml", name, 0),
                "text": "\n".join(lines),
                "metadata": {
                    "source_file": "metrics/metric_dictionary.yaml",
                    "section": name,
                    "doc_type": "metric",
                },
            }
        )

    return docs


def curated_docs(docs_dir: str | Path) -> list[Path]:
    """
    Every markdown file under docs_dir, minus audit/report noise.

    Globbing (rather than a hard-coded list) survives repo consolidation: the
    old silver/gold docs were merged into docs/ARCHITECTURE.md in 2026-11-10,
    and a fixed list would silently index nothing.
    """
    root = Path(docs_dir)
    if not root.exists():
        return []

    found = [
        p for p in sorted(root.rglob("*.md"))
        if p.is_file() and not _SKIP_PATTERNS.search(p.name)
    ]
    return found


def documentation_documents(docs_dir: str | Path) -> list[dict]:
    """Curated markdown files under docs_dir, chunked by heading."""
    root = Path(docs_dir)
    docs: list[dict] = []

    for path in curated_docs(root):
        relative = path.relative_to(root).as_posix()
        source_file = "docs/" + relative
        docs.extend(chunk_markdown(path.read_text(encoding="utf-8"), source_file))

    return docs


def all_doc_chunks(metric_dict_path: str | Path, docs_dir: str | Path) -> list[dict]:
    return metric_documents(metric_dict_path) + documentation_documents(docs_dir)


# ---------------------------------------------------------------------------
# Chroma writes
# ---------------------------------------------------------------------------

def backfill_row_metadata(collection, batch_size: int = 500) -> int:
    """
    Give the existing row documents the unified metadata schema without
    re-embedding them. Safe to call repeatedly.
    """
    result = collection.get(include=["metadatas"])
    ids = result.get("ids") or []
    metadatas = result.get("metadatas") or []

    changed_ids: list[str] = []
    changed_metas: list[dict] = []

    for doc_id, meta in zip(ids, metadatas):
        meta = dict(meta or {})
        if meta.get("doc_type"):
            continue

        meta["doc_type"] = "data_rows"
        meta["source_file"] = meta.get("source_view") or meta.get("source_file") or "unknown"

        if not meta.get("section"):
            start = meta.get("row_start")
            count = meta.get("n_rows")
            if start is not None and count:
                meta["section"] = f"rows {start}-{int(start) + int(count) - 1}"
            else:
                meta["section"] = ""

        changed_ids.append(doc_id)
        changed_metas.append(meta)

    for i in range(0, len(changed_ids), batch_size):
        collection.update(
            ids=changed_ids[i:i + batch_size],
            metadatas=changed_metas[i:i + batch_size],
        )

    return len(changed_ids)


def ingest_docs(
    collection,
    metric_dict_path: str | Path,
    docs_dir: str | Path,
    embedding_model: str,
    *,
    backfill: bool = True,
) -> dict:
    """
    Upsert the documentation corpus into an existing collection.
    Returns counts for logging.
    """
    backfilled = backfill_row_metadata(collection) if backfill else 0

    docs = all_doc_chunks(metric_dict_path, docs_dir)
    if not docs:
        return {"backfilled": backfilled, "docs": 0}

    from sentence_transformers import SentenceTransformer

    model = SentenceTransformer(embedding_model)
    texts = [d["text"] for d in docs]
    embeddings = model.encode(
        texts, batch_size=EMBED_BATCH, show_progress_bar=False
    ).tolist()

    # Replace previous doc chunks only after embeddings succeeded, so a failed
    # run cannot leave the collection without documentation.
    try:
        collection.delete(where={"doc_type": {"$in": ["metric", "documentation"]}})
    except Exception:
        pass

    collection.add(
        ids=[d["id"] for d in docs],
        documents=texts,
        metadatas=[d["metadata"] for d in docs],
        embeddings=embeddings,
    )

    return {"backfilled": backfilled, "docs": len(docs)}
