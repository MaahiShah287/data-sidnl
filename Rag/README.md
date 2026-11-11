# SIDNL Chatbot

Quick-commerce analytics chatbot over the SIDNL silver views. Coverage is
deliberately narrow: price/availability for Blinkit (brand Mr. Munchies only),
shelf position for Blinkit (Amul, Mr. Munchies) and Zepto (Mumbai only); there
are no Instamart or JioMart rows. A LangGraph router sends each question down
one of two paths:

- **SQL path** — the LLM plans a read-only query against the silver views; a
  keyword/allowlist firewall (`src/db/safe_sql.py`) plus a read-only pool
  (`src/db/client.py`) enforce that the bot cannot write.
- **RAG path** — hybrid retrieval (Chroma vectors + BM25, fused with RRF) over
  documentation and data-row chunks, then grade → generate → verify.

## Setup

```powershell
cd Rag
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -e ".[dev]"
copy .env.example .env   # then fill in DATABASE_URL and LLM_API_KEY
```

Run everything with `.\.venv\Scripts\python.exe` from `Rag/`.

## Verify

```powershell
.\.venv\Scripts\python.exe -m pytest -q
.\.venv\Scripts\python.exe -c "import sys; sys.path.insert(0,'src'); from db.client import execute_safe; print(execute_safe('SELECT count(*) FROM silver.v_latest_observation').row_count)"
```

## Build / refresh the index

```powershell
.\.venv\Scripts\python.exe scripts\build_index.py   # full rebuild (~5.5 h on CPU)
.\.venv\Scripts\python.exe scripts\add_docs.py      # append docs only, keeps row embeddings (~30 s)
```

A full rebuild can exit non-zero with a Chroma "Error in compaction" message
*after* the write succeeded — check `collection.count()` before rebuilding
again (see `RAG_PIPELINE_DOCUMENTATION.md` §13).

## Run the API

```powershell
.\.venv\Scripts\python.exe -m uvicorn api.app:app --app-dir src --port 8000
```

## Layout

- `src/config.py` — all settings, sourced from `.env`
- `src/graph/` — LangGraph router, RAG graph, SQL graph
- `src/retrieval/` — hybrid retrieval and documentation indexing
- `src/db/` — connection pool and SQL firewall
- `scripts/` — index builders and ground-truth capture
- `eval/` — evaluation harness and question set
- `metrics/metric_dictionary.yaml` — metric definitions/status

See `RAG_PIPELINE_DOCUMENTATION.md` for how the pipeline works and
`OPEN_QUESTIONS.md` for open data questions.
