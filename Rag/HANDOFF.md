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

0. **Fallback mechanisms (UPDATED 2026-11-10 evening):** Gap 2 (freshness) was implemented by Hardi as `silver_062_bronze_freshness` (already applied). Gaps 3/4/5 are written but **not applied**: `silver_063` (dead-letter, Option A), `silver_064` (heartbeat + lock-safe daily cron), `silver_065` (alert outbox bridging all alert logs incl. freshness to Slack), plus edge functions in `data-sidnl/edge-functions/`. Apply in order **063 → 064 → 065** via Supabase SQL editor (admin), then the `[ADMIN]` items marked inside each file (Gap 3 loader predicates, run_tick/record_storage_snapshot hooks, pg_net enable, edge-function deploy + secrets). Decisions logged in `fallbacks-design.md` header (Q1–Q6). Phase 3 test plan in the same doc.
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

## Session log

### 2026-11-10 — rebuild after the working tree was wiped

**What happened (important for the next person):** the repo was re-cloned to
the consolidated layout *over this working directory*. `git reflog` shows a
single entry, `clone: from github.com/MaahiShah287/data-sidnl`; the Recycle Bin
shows the previous root-level `docs/`, `sql/`, `COMMIT_INSTRUCTIONS.md` and
`MANIFEST.csv` deleted. Consequences:

- **All uncommitted `Rag/` work was lost** — the docs indexer, the metadata
  fixes, the tests and the earlier session log. There was no stash and no
  branch, so nothing was recoverable from git. Everything below was rebuilt
  from scratch; treat it as new work, not as a re-run of finished work.
- `Rag/.venv`, `Rag/chroma_db/` and `Rag/reports/` are absent (all ignored).
- **The docs corpus was consolidated.** `4d2e51d` deleted 14 doc files
  (`silver/SILVER_SCHEMA.md`, `silver/CANONICAL_MAP.md`,
  `silver/SILVER_OPERATIONS.md`, `gold/GOLD_METRIC_VIEWS.md`,
  `fallbacks-design.md`, the audits, the ERDs) and merged them into a single
  `data-sidnl/docs/ARCHITECTURE.md` (155 lines, verified against the live DB).
  The old files remain in git history (`git show 944ecf7:data-sidnl/docs/...`)
  if ever needed. **`src/retrieval/docs_index.py` now globs `docs/**/*.md`
  instead of hard-coding a list**, so the next consolidation does not silently
  index nothing. Audit/report/ERD files are skipped by name.

**Verified working this session:**

- `.venv` rebuilt with Python 3.11.4, `pip install -e ".[dev]"` OK.
- DB reachable through the read-only pool, all three views match the handoff:
  `v_all_platforms` 56,249 / `v_latest_observation` 5,055 /
  `v_latest_shelf_position` 33,991. A `DELETE` is rejected with
  `SQLValidationError` — writes are blocked as designed.
- Docs corpus on the consolidated repo: **16 metric + 16 documentation = 32
  chunks** (metric dictionary + `ARCHITECTURE.md`).
- Test suite: **62 passed** (50 safe-SQL + 12 docs-index).

**Restored/added in this session** (all previously lost):

1. `src/retrieval/docs_index.py` — metric + markdown chunking, append-only
   ingest, metadata backfill (`source_view` → `source_file`, `doc_type`,
   `section="rows a-b"`, keeping `source_view` for backward compatibility).
2. `scripts/add_docs.py` — append docs to an existing collection without
   re-embedding the row documents.
3. `scripts/build_index.py` — row docs now also carry
   `source_file`/`section`/`doc_type`, and a full rebuild ingests docs too.
4. `src/graph/rag_graph.py` — `_source_file()` / `_section()` / `_citation()`
   accept both metadata schemas, so citations no longer render as `unknown#`.
5. `src/retrieval/hybrid.py` — the `SentenceTransformer` is cached per process
   instead of being reloaded on every query.
6. `src/config.py` + `.env.example` — `DOCS_DIR`; `.env.example` now documents
   the IPv4 **pooler** DSN and the real `sidnl_chatbot_app` role.
7. `scripts/run_ground_truth.py` — `parse_dsn()` now uses `urlsplit()`, so
   passwords containing `@` or `:` no longer break the connection.
8. `pyproject.toml` — added `httpx` (used by `eval/run_eval.py`); added the
   missing `README.md` that `readme = "README.md"` requires.

**Doc bug worth fixing in the data repo:** `docs/ARCHITECTURE.md` §8 says
"`Rag/` queries `silver.demo`, which was dropped in `silver_054`". That is
stale — all 22 references to `silver.demo` in `Rag/` are *defensive*: the SQL
firewall, planner prompt, profiler and eval all blocklist or assert against it.
No Rag query reads it.

⚠️ **Chroma version risk:** the index is being rebuilt from scratch under the
resolved Chroma (1.5.9), so the "0.5.x index may not open" risk no longer
applies — but a copied index from an older machine would still hit it.

#### Error 1 — bulk read hits the chatbot's statement timeout

```
Fetching silver.v_all_platforms ...
psycopg.errors.QueryCanceled: canceling statement due to statement timeout
  File "scripts/build_index.py", line 98, in collect_all_documents
    cur.execute(f"SELECT * FROM {view}")
```

Cause: `db/client.py` sets `statement_timeout=10000` as a *connection option*
for the whole pool, so `get_conn()` inherits 10 s. `SELECT *` over
`v_all_platforms` (56,249 rows) needs longer. Do **not** raise the pool's cap —
that is the chatbot's guard against runaway LLM-generated SQL.

Fix: `db/client.py` gains `get_bulk_conn()`, a direct (non-pooled) connection
that is still `default_transaction_read_only=on` but allows
`statement_timeout=600000`; `build_index.py` uses it for ingestion only.

#### Error 2 — the LLM account has no credits (BLOCKER for all LLM paths)

Smoke test of the main graph, `"What is the in-stock rate for Mr Munchies on
Zepto?"`, returned `route=AMBIGUOUS, confidence=0.0` in 7.9 s. That is the
router's *fail-safe*, not a classification: `router_node` catches every
exception and returns AMBIGUOUS with confidence 0.0, discarding the reason
(it is never written to state), so the failure was invisible.

Probing the provider directly:

```
OpenAIRateLimitError: Error code: 429 - You have no credits remaining.
Add credits to continue using the API at https://platform.openai.com/settings/organization/billing/.
```

The key itself is fine (present, 164 chars) and `LLM_API_BASE` is the default
`https://api.openai.com/v1`; the organization simply has a zero balance. This
blocks **router, SQL planner, answer generation, RAG grading/verification and
`eval/run_eval.py`**. Retrieval and the index build do not need the LLM.

Options: add OpenAI credits, or switch to an OpenAI-compatible provider (the
handoff already supports Groq: set `LLM_API_KEY=gsk_...`,
`LLM_API_BASE=https://api.groq.com/openai/v1`, and matching model names).

**Diagnostic gap worth fixing:** an infrastructure failure currently looks
exactly like a real "this question is ambiguous" decision. `ChatState` now
carries `router_error`, so scripts/eval can tell the two apart instead of
silently scoring a 429 as a routing miss.

#### Error 3 — prompts contain literal JSON, so `str.format()` raises KeyError

After switching to Groq the router worked (routed NUMERIC), then the SQL path
died before reaching the model:

```
KeyError: '"error"'
  File "src/graph/sql_graph.py", line 99, in plan_query_node
    prompt = _load_prompt("sql_planner.md").format(
```

Cause: the prompt files contain JSON examples. `str.format()` treats every
`{...}` as a field, so `{"error": "<reason>"}` becomes a lookup of the key
`"error"`. **Four prompts are affected**: `sql_planner.md`,
`rag_grade_relevance.md`, `rag_rewrite.md`, `rag_verify_claims.md`.

This is why neither path ever worked: `.format()` runs *before* the `try`
block in every node, so SQL planning and RAG grading both raise before the
LLM is called. It is invisible in unit tests because no test renders a prompt.

Fix: new `src/graph/prompt_utils.py` with `render(template, **kwargs)`, which
substitutes only `{lower_case_identifier}` placeholders and leaves JSON
braces untouched. All six `.format()` call sites now use it.




