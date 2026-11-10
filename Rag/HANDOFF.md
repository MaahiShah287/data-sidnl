# SIDNL Chatbot — Handoff Notes

_Last updated: 2026-11-10. Setup done end-to-end on Windows; DB connected, RAG index built, LLM configured. Continue from the "Next Steps" section._

## 👉 FOR THE AI AGENT / COLLEAGUE CONTINUING THIS WORK — START HERE

Read this whole file first, then `Rag/OPEN_QUESTIONS.md`. Then, in order:

1. **Verify the environment works** (don't trust, verify): run the 4 commands in "How to run / verify setup" below. All should pass before anything else.
2. **First real task:** end-to-end smoke test of the app — run `src/api/app.py` with uvicorn and ask "What is the in-stock rate for <a brand> on Zepto?". This exercises router → SQL path → generation. Fix whatever breaks (report the exact error in this file before fixing, so the next person sees the history).
3. **Second task:** fill ground truth (`scripts/run_ground_truth.py`) and run `eval/run_eval.py` to get baseline scores for the RAG path.
4. **Owner's declared next phase:** the silver→gold pipeline work (see `data-sidnl/sql/`, `docs/gold/GOLD_METRIC_VIEWS.md`). The chatbot side is unblocked; pipeline work resumes there.
5. Do NOT re-do anything in "What was already done" below. Do NOT touch `Rag/.env` except to read it for local runs; never commit it, never print its values into chat or docs.

Rules of thumb: run everything with `Rag/.venv/Scripts/python.exe` from `Rag/`; keep `.env.example` in sync when adding a new variable; update this file's "Next steps" as items complete.

## What is this project?

A quick-commerce (Blinkit/Zepto/Instamart/Jiomart) analytics chatbot in `Rag/`:
LangGraph router → either a **RAG pipeline** (retrieve docs from Chroma → grade → generate → verify) or a **SQL path** (LLM plans SQL against the read-only silver views → executed via a SQL firewall). Config centrally lives in `Rag/src/config.py`, all values from `Rag/.env`.

## What was already done (do not redo)

### 1. Environment / dependencies
- **Bug fix:** `Rag/pyproject.toml` had an invalid build backend (`setuptools.backends.legacy:build`). Corrected to `setuptools.build_meta`. If a fresh machine fails `pip install -e .` with `No module named 'setuptools.backends'`, this fix is already committed.
- Venv lives at `Rag/.venv` (git-ignored). Activate with `.\.venv\Scripts\Activate.ps1` and run everything with `.\.venv\Scripts\python.exe`.
- All deps from `pyproject.toml` installed successfully.

### 2. Database (Supabase, project `jqxnaqbvwgmfkyzfincy`, region `ap-south-1`)
- **Read-only role:** `sidnl_chatbot_app` exists, `LOGIN`, **non-superuser**, and has direct `SELECT`-only grants on ~40 silver views/dims (verified via `information_schema.role_table_grants` — all rows `SELECT`). The group role `sidnl_chatbot_ro` from `sql/03_roles.sql` was never created; grants were applied directly to `_app` instead. Functionally equivalent for read-only enforcement, just a simpler topology.
- **Password reset done** via `ALTER ROLE sidnl_chatbot_app WITH PASSWORD '...'` in Supabase SQL Editor (current password is recorded in the real `Rag/.env` — never commit or paste it). Consider rotating before any deploy.
- **Connection quirk (IMPORTANT):** Supabase *direct* hosts (`db.<ref>.supabase.co`) are **IPv6-only**; the original network can't route IPv6 → DNS/connect failures. Solution: use the **IPv4 session pooler**:
  ```
  DATABASE_URL=postgresql://sidnl_chatbot_app.jqxnaqbvwgmfkyzfincy:<password>@aws-0-ap-south-1.pooler.supabase.com:5432/postgres
  ```
  Note the pooler requires `<user>.<project-ref>` before the password. Verified working.
- **Chatbot privileges:** reads the three allowlisted views via a pool whose connections are forced `default_transaction_read_only=on` with `statement_timeout=10s` (`src/db/client.py`), plus a keyword/allowlist SQL firewall (`src/db/safe_sql.py`). The bot cannot write.

### 3. RAG index (Chroma)
- **New file:** `Rag/scripts/build_index.py` (this did not exist before). It:
  - pulls rows from the three allowlisted views,
  - groups 25 rows into one text document (`col: value | col: value` lines, metadata: `source_view`, `platform`, `store`),
  - embeds locally with `intfloat/multilingual-e5-base`, writes to Chroma collection `sidnl_docs` at `./chroma_db` (paths from `.env`).
- **Important detail:** ingestion reads via the read-only pool *directly* (`db.client.get_conn`), NOT `execute_safe`, because `safe_sql.py` auto-appends `LIMIT 200` to every query — using it silently truncated the index. Keep this in mind if you add more views; use direct pool reads for ingestion, never `execute_safe` for bulk loads.
- Final index: **3,813 documents** from 56,249 (`v_all_platforms`) + 5,055 (`v_latest_observation`) + 33,991 (`v_latest_shelf_position`) rows. Build takes ~45-50 min on CPU.
- Re-running `build_index.py` deletes and re-creates the collection (always mirrors the views).
- Retrieval smoke test passed: `retrieval.hybrid.retrieve('zepto in stock rate')` returns hits from the index.

### 4. LLM
- OpenAI provider configured in `Rag/.env` (`LLM_API_KEY`, `LLM_API_BASE=https://api.openai.com/v1`, `gpt-4o-mini` for generator/critic/router). `ChatOpenAI` is used everywhere with `base_url` from config, so any OpenAI-compatible endpoint (e.g. Groq with `LLM_API_BASE=https://api.groq.com/openai/v1`) works by swapping key+URL+model names.
- ⚠️ An earlier OpenAI key was exposed while debugging and **should be treated as revoked**; use only the current key in `.env`.

## How to run the chatbot / verify setup (fresh machine)

```powershell
cd Rag
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -e .
# put real values in .env (see .env.example; pooler URL format above)
.\.venv\Scripts\python.exe -c "import sys; sys.path.insert(0,'src'); from db.client import execute_safe; r=execute_safe('SELECT count(*) FROM silver.v_latest_observation'); print(r.row_count,'rows OK')"
.\.venv\Scripts\python.exe scripts\build_index.py   # only if rebuilding the index
```

## Next steps / pending work

1. **End-to-end smoke test of the app** (`src/api/app.py` with uvicorn) — the LLM path has NOT been exercised against real queries yet. Do a question like "What is the in-stock rate for Zenly on Zepto?" and confirm routing, SQL, and generation all work.
2. **RAG pipeline quality** — the retrieval → grade → generate → verify graph (`src/graph/rag_graph.py`, prompts in `src/prompts/`) was wired but not evaluated. Run `Rag/eval/run_eval.py` after filling ground truth via `scripts/run_ground_truth.py`, and look at `Rag/OPEN_QUESTIONS.md` open items.
3. **E5 prefixes** — `multilingual-e5-base` is trained with `query:`/`passage:` prefixes. Current code embeds bare strings in both `build_index.py` and `hybrid.py` (consistent, but suboptimal). If answer quality is weak, add prefixes to BOTH files together.
4. **Rotation/cleanup** — rotate the role password once more (it appeared in chat logs), and confirm `.env` never gets committed (`git check-ignore Rag/.env`).
5. **`sql/02_diagnostics.sql`** — still open per `OPEN_QUESTIONS.md`: run blocks against Supabase to resolve `scrape_status` TODOs in `01_views.sql`.
6. **Pipeline (next phase, owner noted in chat):** continue silver→gold pipeline work as before; the chatbot side is now unblocked for that work.

## Working directory layout (relevant bits)

- `Rag/.env` — real secrets (git-ignored, DO NOT commit)
- `Rag/.env.example` — template (committed)
- `Rag/scripts/build_index.py` — index builder (new)
- `Rag/scripts/profile_data.py` — Stage A profiler (still unrun; needs DB_URL — now available)
- `Rag/src/db/` — pool client + SQL firewall
- `Rag/src/graph/` — LangGraph router/RAG/SQL
- `Rag/eval/`, `Rag/metrics/` — evaluation + metric dictionary
- `data-sidnl/sql/` — silver/gold pipeline SQL (other part of the project)
