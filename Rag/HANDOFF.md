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
- Final index: **3,845 documents** = 3,813 row chunks (from 56,249 `v_all_platforms` + 5,055 `v_latest_observation` + 33,991 `v_latest_shelf_position` rows, 25 rows per chunk) + 32 doc chunks (16 metric + 16 documentation). A full rebuild took **5 h 29 min** on CPU (torch uses 10/12 cores); `scripts/add_docs.py` appends docs in ~30 s without re-embedding rows.
- Re-running `build_index.py` deletes and re-creates the collection (always mirrors the views). It can exit non-zero on a post-write Chroma compaction error even though the data landed — see Error 4.
- Retrieval smoke test passed: `retrieval.hybrid.retrieve('zepto in stock rate')` returns hits from the index.

### 4. LLM
- **Current provider: Groq** (`LLM_API_BASE=https://api.groq.com/openai/v1`, model `openai/gpt-oss-120b`) — OpenAI returned `429 You have no credits remaining`, so the OpenAI key is dead but the code path is unchanged (see Error 2).
- `ChatOpenAI` is used everywhere with `base_url` from config, so any OpenAI-compatible endpoint works by swapping key + URL + model names.
- ⚠️ Two keys have been exposed while debugging and **must be treated as revoked**: the earlier OpenAI key, and the Groq `gsk_...` key pasted in chat on 2026-11-11. Use only a freshly rotated key in `.env`.

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
1. **End-to-end smoke test of the app** — **DONE 2026-11-11.** `uvicorn api.app:app`
   on :8000, all four routes exercised (NUMERIC / DEFINITION / UNSUPPORTED /
   AMBIGUOUS), `router_error` unset, smoke script exits 0.
2. **RAG pipeline quality** — baseline done 2026-11-11 (`Rag/reports/eval_baseline.md`).
   The planner literal-value bug is fixed (Error 5) and spot-checked 6/6; a full
   75-question re-run on `openai/gpt-oss-120b` is pending the daily quota reset.
   `metrics/status_vocabulary.md` is now indexed, so "what does draft status
   mean" has a source.
3. **E5 prefixes** — **CLOSED 2026-11-11.** Measured on the 32 doc chunks; the
   gain is negligible and the right chunk already ranks #1. Do **not** re-embed
   3,813 rows for prefixes. Relevance was fixed with route-aware `doc_types`
   filtering instead (see session log).
4. **Rotation/cleanup** — the Groq key was pasted in chat and **must be
   rotated** (console.groq.com → API keys). It was also echoed into a terminal
   transcript on 2026-11-11 (`Get-Content .env` filter matched `LLM_API_KEY`),
   so treat it as compromised. Also rotate the role password once more (it
   appeared in chat logs), and confirm `.env` never gets committed
   (`git check-ignore Rag/.env`).
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

#### Error 4 — Chroma raises a compaction error *after* a successful write

```
chromadb.errors.InternalError: Error in compaction: Failed to apply logs to
the metadata segment
  File "scripts/build_index.py", line 175, in build
    collection.add(ids=..., documents=..., metadatas=..., embeddings=...)
```

The run had already spent **5 h 29 min** embedding 3,813 documents. The
exception looked like data loss, but it is not:

```python
col.count()            # 3813
col.get(limit=3, ...)  # returns ids + metadata + documents
col.query(...)         # returns hits
```

`chroma_db/chroma.sqlite3` is ~681 MB and the collection is complete. Chroma
1.5.9 fails in a *post-write compaction* step, so the rows are durable and the
error is cosmetic — but the build script cannot tell the difference and exits
non-zero.

**Do not re-embed to "fix" this.** Verify with `col.count()` / `col.get()` /
`col.query()` first. To append documentation to an existing collection use
`scripts/add_docs.py`, which took ~30 s instead of 5.5 h:

```
Backfilled metadata on 0 row documents; upserted 32 doc chunks.
Collection now has 3845 documents (was 3813).
```

**Fixed 2026-11-11:** `build_index.py` now (a) writes in `ADD_BATCH = 256`
chunks so one failed transaction cannot take out the whole load, and (b) caches
the embeddings in `reports/embed_cache/rows-<fingerprint>.npy` (git-ignored,
keyed by a hash of ids+texts+model). A re-run with an unchanged corpus reuses
the array and skips the ~5.5 h encode entirely. The fingerprint includes the
document text, so editing row text invalidates the cache automatically.

A second, unrelated symptom followed: the next Chroma process hung for >15 min
with no output while a `chroma.sqlite3-journal` was present. Direct SQLite
access showed the DB was healthy (`collections: 1`, `embeddings: 3845`,
`metadata rows: 34445`) and the journal disappeared; subsequent Chroma opens
took 0.5 s. If this recurs, check for the journal file and a stale process
before assuming corruption.

#### Retrieval relevance — route-aware filtering, not E5 prefixes

`retrieve("What is observed_in_stock_rate and how is it calculated?")` put the
correct metric chunk at #1 in a docs-only ranking but **5th** in the real hybrid
search, because 3,813 `data_rows` chunks outrank the 32 `metric`/`documentation`
chunks in RRF fusion.

Measured E5 `query:`/`passage:` prefixes on the 32 doc chunks: they barely
change ranking (the right chunk is already #1 without them), so re-embedding
3,813 rows for prefixes was **rejected** as a 5.5 h cost for no gain.

Fix instead: `retrieve(query, top_k, doc_types=...)` filters *both* the vector
query (`where={"doc_type": {"$in": [...]}}`) and the BM25 candidate list;
`rag_graph.retrieve_node` passes `["metric", "documentation"]` only for the
DEFINITION route. After the fix, `observed_in_stock_rate` ranks first and
`avg_discount_pct` ranks first for its question.

#### Eval rewrite — the original questions did not match the data

`reports/eval_feasibility.md` (generated by `scripts/run_ground_truth.py`'s
sibling audit) found only **2 answerable, 2 degraded and 21 not answerable**
questions out of the original 25 NUMERIC set. The original ground-truth SQL
also contradicted the question text in 18 of 25 cases (e.g. N02 asked for
Zepto/Mumbai/Haldiram but filtered `blinkit`/`Mr. Munchies`), so those values
were discarded rather than tuned.

Decision (user-approved, "hybrid: honesty + accuracy"):

- keep **8** unanswerable questions as `expect_no_data` honesty tests — the bot
  must abstain, not silently change filters;
- rewrite the remaining questions to real data and add 10 new answerable ones
  (N26–N35);
- add an explicit `primary_column` per question, because the
  `extract_primary_value` heuristic returned `listing_count` instead of the
  metric (N07 reported 489 listings instead of 68 stores);
- `eval/run_eval.py` scores `no_data_correct` and treats `expect_no_data` as
  "abstention is the correct answer".

Resulting set: **75 questions** — 37 NUMERIC (25 slots + N26–N35), 8
`expect_no_data`, 27 answerable overall, 38 non-numeric. All 35 SQL-bearing
questions execute; the 8 coverage gaps return 0 rows.

### 2026-11-11 — verification, API smoke test, eval baseline

- All 75 tests pass (`pytest -q`), `compileall` clean.
- `uvicorn api.app:app` on :8000: all four routes exercised. NUMERIC, DEFINITION,
  UNSUPPORTED and AMBIGUOUS each return the expected route with `router_error`
  unset. `"What is the in-stock rate for Mr Munchies on Zepto?"` correctly
  abstains (no Zepto price/stock rows) instead of inventing a number.
- `metrics/status_vocabulary.md` added and `metrics/*.md` is now indexed, so
  "what does draft status mean?" has prose to retrieve. `metrics/` files are
  chunked by heading with a `metrics/<file>.md` citation prefix.
- Accuracy fixes: the AMBIGUOUS clarifier no longer offers "Delivery ETA"
  (100% NULL) or lists Instamart/JioMart as if they had rows; the router prompt
  now routes ETA and Instamart/JioMart questions to UNSUPPORTED and states the
  real coverage.
- Baseline: `eval/run_eval.py --timeout 240 --passes 2` against the running API.
  The default 60 s timeout is too short — DEFINITION calls were observed at
  93 s. Results in `reports/eval_results.jsonl` (git-ignored); summary in
  `reports/eval_baseline.md`.
- **Environment note:** the dev machine hit 0 bytes free mid-session, which
  made an editor write truncate `scripts/build_index.py` to 0 bytes. It was
  restored with `git checkout --` and re-applied. Freeing the pip cache
  (~1.9 GB) and `%TEMP%` fixed it. If an edit fails oddly, check disk space
  before debugging the file.
- **Baseline result:** pass 1 scored `route_correct` 89% (97% excluding three
  mislabelled adversarial questions), `no_data_correct` 8/8, `no_demo_leak`
  75/75, `sql_safe` 34/34, `source_cited` 15/15, no hallucinations — and
  `numeric_correct` **0/27**, because of Error 5 below. Details and caveats in
  `reports/eval_baseline.md`.
- **Pass 2 is invalid:** 57 of 75 requests hit Groq's daily token cap; the
  router fails safe to AMBIGUOUS, so the "53 unstable questions" figure is an
  infrastructure artifact. Do not quote it.

#### Error 5 — the planner used title-case literals, so every NUMERIC query returned 0 rows

Symptom: `numeric_correct` was 0/27 and every NUMERIC answer was
"No matching observations found", even though the SQL was valid and `sql_safe`
passed.

Cause: the generated SQL filtered `platform = 'Blinkit'`, but the views store
`'blinkit'` and Postgres string comparison is case-sensitive:

| Query against `silver.v_latest_observation` | Rows |
|---|---|
| `platform = 'Blinkit' AND brand = 'Mr. Munchies'` | **0** |
| `platform = 'blinkit' AND brand = 'Mr. Munchies'` | **1**, `in_stock_rate_pct = 7.60` (GT 7.6) |

The same queries also invented filters the question did not ask for
(`availability = true`, `product_name ILIKE '%Mr. Munchies%'` to filter a
brand) and used `city = 'Bangalore'` where the data stores `'Bengaluru'`.

A second, related defect surfaced in the post-fix check: exact
`product_name = 'Mr. Munchies Cheese Chilli Samosa'` matched nothing because the
stored name is `'Mr. Munchies Cheese Chilli Samosa (Frozen)'`.

**Fix:** `src/prompts/sql_planner.md` now lists the exact literal values
(`platform` lowercase, `source_type`, the 11 city spellings, brand examples),
states that `delivery_eta_minutes` is always NULL, tells the planner to match
products with `product_name ILIKE '%<distinctive words>%'`, and forbids adding
filters the question did not ask for.

**Verified (6/6):** N26, N01, N34, N07, N33 and D03 all pass — lowercase
`'blinkit'`, rows returned, ground-truth value present in the answer, D03
citing `metrics/status_vocabulary.md`. The four-route API smoke test passes with
`router_error` unset.

**Caveat:** `openai/gpt-oss-120b` exhausted its 200,000-token daily cap during
the baseline, so the post-fix spot check ran on a temporary `:8001` server with
the three `LLM_*_MODEL` env vars set to `openai/gpt-oss-20b` (separate quota).
Code, prompts, DB and index were unchanged. A full 75-question re-run on 120b is
still pending.

**Operational note:** the Groq API key was exposed in a terminal transcript
during this session (a `Get-Content .env` filter matched `LLM_API_KEY`). Rotate
it in the Groq console and update `.env` before the next long run. Never print
`.env`; filter on specific non-secret keys only.




