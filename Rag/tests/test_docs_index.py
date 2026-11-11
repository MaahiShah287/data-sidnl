"""
tests/test_docs_index.py — unit tests for src/retrieval/docs_index.py.

Covers markdown chunking, metric-dictionary docs, docs-dir discovery, the
metadata backfill (no re-embedding), and the citation helpers that keep
rag_graph from rendering "unknown#".
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from pathlib import Path

from retrieval.docs_index import (
    all_doc_chunks,
    backfill_row_metadata,
    chunk_markdown,
    curated_docs,
    documentation_documents,
    metric_documents,
    _split_long,
)


# ---------------------------------------------------------------------------
# Chunking
# ---------------------------------------------------------------------------

def test_chunk_markdown_splits_on_headings():
    md = "# Title\n\nintro text\n\n## Section A\n\nbody a\n\n## Section B\n\nbody b\n"
    docs = chunk_markdown(md, "docs/x.md")
    sections = [d["metadata"]["section"] for d in docs]
    assert sections == ["Title", "Section A", "Section B"]
    assert all(d["metadata"]["doc_type"] == "documentation" for d in docs)
    assert all(d["metadata"]["source_file"] == "docs/x.md" for d in docs)
    # text is prefixed with origin + section so BM25 has the words
    assert docs[1]["text"].startswith("[docs/x.md — Section A]")


def test_chunk_markdown_ignores_headings_inside_code_fences():
    md = "# Real\n\n```\n# not a heading\n```\n\nbody\n"
    docs = chunk_markdown(md, "docs/x.md")
    assert len(docs) == 1
    assert docs[0]["metadata"]["section"] == "Real"
    assert "# not a heading" in docs[0]["text"]


def test_split_long_respects_max_chars_and_overlaps():
    text = "\n\n".join(f"paragraph {i} " + "x" * 300 for i in range(6))
    chunks = _split_long(text, max_chars=500, overlap=50)
    assert len(chunks) > 1
    assert all(len(c) <= 500 + 60 for c in chunks)  # allow the overlap tail


def test_doc_ids_are_stable_and_unique():
    md = "# A\n\nbody\n\n## B\n\nbody\n"
    first = chunk_markdown(md, "docs/x.md")
    second = chunk_markdown(md, "docs/x.md")
    assert [d["id"] for d in first] == [d["id"] for d in second]
    assert len({d["id"] for d in first}) == len(first)


# ---------------------------------------------------------------------------
# Metric dictionary
# ---------------------------------------------------------------------------

def test_metric_documents_one_per_metric(tmp_path):
    path = tmp_path / "metric_dictionary.yaml"
    path.write_text(
        "metrics:\n"
        "  - name: in_stock_rate\n"
        "    status: draft\n"
        "    source_view: silver.v_latest_observation\n"
        "    definition: Share of observed SKUs that are in stock.\n"
        "  - name: sales\n"
        "    status: unsupported\n",
        encoding="utf-8",
    )
    docs = metric_documents(path)
    assert len(docs) == 2
    assert docs[0]["metadata"] == {
        "source_file": "metrics/metric_dictionary.yaml",
        "section": "in_stock_rate",
        "doc_type": "metric",
    }
    assert "Share of observed SKUs" in docs[0]["text"]
    assert "Status: unsupported" in docs[1]["text"]


def test_metric_documents_missing_file_returns_empty(tmp_path):
    assert metric_documents(tmp_path / "nope.yaml") == []


# ---------------------------------------------------------------------------
# Docs directory discovery
# ---------------------------------------------------------------------------

def test_curated_docs_finds_markdown_and_skips_audit_noise(tmp_path):
    (tmp_path / "ARCHITECTURE.md").write_text("# A\n\nbody\n", encoding="utf-8")
    (tmp_path / "sub").mkdir()
    (tmp_path / "sub" / "SCHEMA.md").write_text("# S\n\nbody\n", encoding="utf-8")
    (tmp_path / "SILVER_AUDIT_2026.md").write_text("# audit\n", encoding="utf-8")
    (tmp_path / "COMPLETION_REPORT.md").write_text("# report\n", encoding="utf-8")
    (tmp_path / "notes.txt").write_text("not markdown\n", encoding="utf-8")

    names = [p.name for p in curated_docs(tmp_path)]
    assert "ARCHITECTURE.md" in names
    assert "SCHEMA.md" in names
    assert "SILVER_AUDIT_2026.md" not in names
    assert "COMPLETION_REPORT.md" not in names
    assert "notes.txt" not in names


def test_documentation_documents_uses_docs_prefix(tmp_path):
    (tmp_path / "ARCHITECTURE.md").write_text("# A\n\nbody\n", encoding="utf-8")
    docs = documentation_documents(tmp_path)
    assert docs[0]["metadata"]["source_file"] == "docs/ARCHITECTURE.md"


def test_all_doc_chunks_combines_both_sources(tmp_path):
    metrics = tmp_path / "m.yaml"
    metrics.write_text("metrics:\n  - name: m1\n    definition: d\n", encoding="utf-8")
    docs_dir = tmp_path / "docs"
    docs_dir.mkdir()
    (docs_dir / "ARCHITECTURE.md").write_text("# A\n\nbody\n", encoding="utf-8")
    chunks = all_doc_chunks(metrics, docs_dir)
    kinds = {c["metadata"]["doc_type"] for c in chunks}
    assert kinds == {"metric", "documentation"}


# ---------------------------------------------------------------------------
# Metadata backfill (the "unknown#" bug)
# ---------------------------------------------------------------------------

class FakeCollection:
    def __init__(self, ids, metadatas):
        self._data = dict(zip(ids, [dict(m) for m in metadatas]))
        self.updates = 0

    def get(self, include=None):
        return {"ids": list(self._data), "metadatas": [dict(m) for m in self._data.values()]}

    def update(self, ids, metadatas):
        self.updates += 1
        for i, m in zip(ids, metadatas):
            self._data[i] = dict(m)


def test_backfill_adds_unified_schema_and_keeps_source_view():
    coll = FakeCollection(
        ["row:0", "row:1"],
        [
            {"source_view": "v_all_platforms", "row_start": 0, "n_rows": 25},
            {"source_view": "v_latest_observation", "row_start": 25, "n_rows": 25},
        ],
    )
    changed = backfill_row_metadata(coll)
    assert changed == 2
    first = coll._data["row:0"]
    assert first["doc_type"] == "data_rows"
    assert first["source_file"] == "v_all_platforms"
    assert first["section"] == "rows 0-24"
    assert first["source_view"] == "v_all_platforms"  # backward compatibility
    assert coll._data["row:1"]["section"] == "rows 25-49"


def test_backfill_is_idempotent():
    coll = FakeCollection(
        ["row:0"], [{"source_view": "v", "row_start": 0, "n_rows": 5}]
    )
    assert backfill_row_metadata(coll) == 1
    assert backfill_row_metadata(coll) == 0  # already has doc_type
    assert coll._data["row:0"]["section"] == "rows 0-4"


def test_backfill_leaves_existing_doc_chunks_alone():
    coll = FakeCollection(
        ["doc:1"],
        [{"source_file": "docs/A.md", "section": "S", "doc_type": "documentation"}],
    )
    assert backfill_row_metadata(coll) == 0
    assert coll._data["doc:1"]["section"] == "S"


# ---------------------------------------------------------------------------
# Citation helpers
# ---------------------------------------------------------------------------

def test_citation_helpers_handle_both_metadata_schemas():
    from graph.rag_graph import _citation, _source_file

    row_meta = {"source_view": "v_all_platforms", "section": "rows 0-24"}
    doc_meta = {"source_file": "docs/ARCHITECTURE.md", "section": "2. Silver tables"}
    assert _citation(row_meta) == "v_all_platforms#rows 0-24"
    assert _citation(doc_meta) == "docs/ARCHITECTURE.md#2. Silver tables"
    assert _source_file({}) == "unknown"
    assert _citation({}) == "unknown"
