# SIDNL RAG Chatbot — Pipeline Documentation

A plain-language guide to what this chatbot is, how a question flows through it,
what safety rails exist, and how to run it. Written so a new team member can
pick it up without any prior context.

---

## 1. What is this and why does it exist?

The SIDNL chatbot answers questions about quick-commerce data (Blinkit and
Zepto) in two very different ways:

- **Numbers** ("What is the in-stock rate for Mr. Munchies on Blinkit?") are
  answered by generating a **read-only SQL query** against Postgres.
- **Definitions** ("What does `observed_in_stock_rate` mean?") are answered by
  **retrieving documentation** and writing an answer from it (RAG).

The purpose is to let analysts ask questions in English (or Hindi/Hinglish)
without writing SQL, while **never inventing numbers** and **never modifying the
database**.

The guiding principle is: *if the data cannot support the answer, say so.*
Abstaining is a correct answer. Making up a number is not.

---

## 2. What data can it actually answer? (coverage)

This is intentionally narrow. Do not expect the bot to answer everything.

Two layers are queryable. **Gold (`dash`) is authoritative for KPIs; Silver is
for the individual raw reading.**

| Layer | What it holds | Use it for |
|---|---|---|
| **Silver** | raw, quality-filtered SKU × store readings: price, availability, discount, shelf position, ads | "what is the price / stock / shelf position of this SKU at this store right now" |
| **Gold (`dash`)** | pre-aggregated dashboard tables and views, built from Silver by the Gold refresh | any KPI: OSA, listing, stockouts, DOI, price parity, SOH, SOV, rank, GMV/units/ASP/growth, ad spend/ROAS/ACOS, fill rate, PO/invoice value, serviceability, freshness |

Silver coverage:

| Data | Platform | Scope |
|---|---|---|
| Price, availability, discount | **Blinkit** | Brand **Mr. Munchies** only |
| Shelf position, organic position, ads | **Blinkit** | Brands **Amul** and **Mr. Munchies** |
| Shelf position, organic position, ads | **Zepto** | **Mumbai only** |

Gold coverage (all in `dash`):

| Area | Tables / views | Metrics |
|---|---|---|
| Availability / OSA | `availability`, `v_chatbot_availability_city` | OSA %, listing %, in/out-of-stock stores, DOI, potential sales loss |
| Pricing / parity | `pricing`, `v_comp_price_gap`, `v_comp_cross_marketplace` | MRP, SP, discount %, parity break, cross-platform gap, price index |
| Visibility / SOV / SOH | `visibility`, `v_brand_scorecard`, `v_brand_scorecard_latest`, `comp_brand_day` | share of voice, share of shelf, shelf rank, impressions |
| Competitor layer | `comp_brand_day`, `comp_sku_day`, `v_comp_sku_day` | competitor price/availability/shelf |
| First-party sales | `fp_sales_daily`, `v_fp_sales_day/_sku/_city/_month/_health` | GMV, units, ASP, 28-day growth |
| First-party ads | `fp_ad_page_perf`, `v_fp_ad_page`, `v_fp_ad_wallet_day` | impressions, clicks, CTR, CPC, CPM, CVR, spend, ROAS, ACOS |
| Supply chain / finance | `fp_fill_rate`, `fp_po`, `fp_po_line`, `fp_grn_line`, `fp_invoice`, `v_fp_po_summary`, `v_fp_finance_summary` | fill rate, PO value/shortfall, invoice/pending value |
| Coverage / freshness | `coverage`, `v_platform_freshness`, `v_refresh_status` | serviceability, data freshness |

**Genuinely unavailable:** delivery ETA (column exists but is NULL in every
row), Instamart, JioMart, and industry market share / total category size.

Cities present in Silver (11):
`Ahmedabad`, `Bengaluru`, `Chennai`, `Delhi`, `Gurugram`, `Hyderabad`,
`Kolkata`, `Mumbai`, `Navi Mumbai`, `Pune`, `Thane`.
Gold uses `city_slug` (resolve it through `dash.dim_city`); the pseudo-city
`'ALL'` is an all-city roll-up and must never be added to city rows. Platform
values are lowercase in both layers.

Three read-only Postgres views back the Silver path:

| View | Rows | Grain |
|---|---|---|
| `silver.v_all_platforms` | ~56,249 | every row, both source types, quality-filtered |
| `silver.v_latest_observation` | ~5,055 | latest price/availability/discount per listing+store |
| `silver.v_latest_shelf_position` | ~33,991 | latest shelf position/ad data per listing+store |

The Gold path reads the curated `dash.*` tables/views directly. `dash` has 30
tables and 25 views; `sql/01_views.sql` documents the map and
`dash.metric_catalog` is the authoritative 57-metric list (formula, status,
source columns).

**Storage quirks that matter when writing SQL:**

- `platform` is **lowercase**: `'blinkit'`, `'zepto'`. `'Blinkit'` returns zero rows.
- `source_type` is `'observation'` or `'shelf_position'`.
- `brand` is its own column (`'Mr. Munchies'`), not part of `product_name`.
- `product_name` carries qualifiers, e.g.
  `'Mr. Munchies Cheese Chilli Samosa (Frozen)'` — match with `ILIKE '%…%'`,
  not `=`.
- `availability` is a boolean and is NULL for some rows.
- Gold's date column is `obs_date` (`sales_date` / `day` / `as_of` for
  first-party tables), not `observed_at`.
- `dash.availability` mixes city totals (`store_key IS NULL`) with per-dark-store
  rows. Summing both double-counts. The chatbot uses
  `dash.v_chatbot_availability_city`, which only exposes city totals.
- Gold percentages must roll up as `SUM(numerator) / SUM(denominator)`, never
  `AVG(pct)`. Brand-level SOV is `SUM(brand SKU impressions) / SUM(market
  impressions)`, never an average of `share_of_voice_pct`.

---

## 3. The big picture

```
                       ┌──────────────────────────────┐
  POST /chat  ────────►│  Router (LLM classification) │
  {question}           └──────────────┬───────────────┘
                                      │
          ┌───────────────┬───────────┴───────────┬────────────────┐
          ▼               ▼                       ▼                ▼
       NUMERIC        DEFINITION            UNSUPPORTED        AMBIGUOUS
          │               │                       │                │
          ▼               ▼                       ▼                ▼
     SQL subgraph    RAG subgraph          "we don't have      one clarifying
   plan→validate→   retrieve→grade→         this data" +       question with
   execute→repair→  generate→verify→        real coverage      examples
   verify→format    finalize/abstain
          │               │
          └───────┬───────┘
                  ▼
        answer + sql/rows/sources + trace
```

Every response also carries `abstain_reason` (why it refused, if it did),
`latency_ms`, and a per-node `trace` so you can see where time went.

The **NUMERIC** subgraph queries both layers: Silver for raw readings, Gold
(`dash`) for KPIs. Gold KPIs (sales, SOV, SOH, ROAS, clicks, impressions, …) are
no longer sent to `UNSUPPORTED`; only delivery ETA, Instamart, JioMart and
industry market share are.

---

## 4. Stage 1 — the API

`src/api/app.py` is a small FastAPI app with two endpoints:

| Endpoint | Purpose |
|---|---|
| `GET /health` | liveness check, returns `{"ok": true}` |
| `POST /chat` | body `{"question": "..."}` → full answer object |

Response shape:

```json
{
  "answer": "The overall in-stock rate ... is 7.60 %",
  "route": "NUMERIC",
  "router_error": null,
  "abstain_reason": null,
  "sql": "SELECT ... LIMIT 200",
  "rows": [{"platform": "blinkit", "in_stock_rate_pct": 7.6}],
  "sources": ["SELECT ..."],
  "retry_count": 0,
  "metric_status": "draft",
  "latency_ms": 8123.4,
  "trace": [{"node": "router", "latency_ms": 700}]
}
```

`router_error` is important: if the LLM provider fails (e.g. rate limit), the
router fails safe to `AMBIGUOUS` **and records the error here**. Without this
field, provider outages look like routing mistakes.

---

## 5. Stage 2 — routing

`src/graph/router.py` asks the LLM to classify the question into exactly one of
four routes. The prompt lives in `src/prompts/router_system.md`.

| Route | Meaning | Example |
|---|---|---|
| `NUMERIC` | a number/rate/comparison/list answerable from Silver or Gold | "What was our GMV last month?" |
| `DEFINITION` | asks what something means | "What is the difference between SOV and SOH?" |
| `UNSUPPORTED` | asks for data SIDNL does not have | "What is the delivery ETA on Blinkit?" |
| `AMBIGUOUS` | too vague to answer without clarification | "How is Blinkit doing?" |

Rules encoded in the router prompt (`src/prompts/router_system.md`, v2.0):

- **NUMERIC** covers both layers. Anything that sounds like a KPI is numeric:
  sales, revenue, GMV, units, ASP, growth, OSA, listing, SOV, SOH, price parity,
  ROAS, ad spend, CTR, clicks, impressions, conversion, fill rate,
  serviceability, invoice/pending value.
- **UNSUPPORTED** is reserved for genuinely absent data:
  - delivery ETA (the column exists but is NULL in every row);
  - any Instamart or JioMart question (no rows);
  - industry market share / total category size (no category-size input).
- The prompt explicitly lists the Gold KPIs that must **not** be sent to
  `UNSUPPORTED`, and states the real Silver coverage so the router does not
  pretend every SKU × store reading exists.
- `src/graph/router.py` also has a fast keyword override. It now only
  short-circuits Instamart, JioMart, delivery ETA and industry market share;
  the old override that sent sales/SOV/SOH/ROAS/clicks/impressions to
  `UNSUPPORTED` was removed. The override also skips the "tell me about…"
  clarification when the question names a metric.

If the router LLM call throws, the state becomes `AMBIGUOUS` and `router_error`
is set. That is a deliberate fail-safe: ask a clarifying question rather than
guess.

---

## 6. Stage 3a — the SQL path (NUMERIC)

`src/graph/sql_graph.py` is a LangGraph subgraph with this flow:

```
plan_query → validate_sql → execute_sql → verify_numeric → format_answer
                   │              │
                   └── repair_sql ┘   (max ONE repair)
                          │
                     sql_abstain / zero_rows
```

**plan_query** — loads `metrics/metric_dictionary.yaml`, matches a metric by
name **or alias** (longest phrase wins, word-boundary aware), and asks the LLM
(prompt: `src/prompts/sql_planner.md`) for a single `SELECT` in JSON:
`{"sql": "..."}` or `{"error": "..."}`.

The planner prompt contains:

- the exact Silver literal values (lowercase platforms, the 11 city spellings,
  brand examples) and the rule: *only add filters the question asks for*;
- the full Gold relation map (tables, views, columns) and the Gold conventions
  (`obs_date`, `city_slug` vs `dim_city`, `SUM(num)/SUM(den)`, `store_key IS
  NULL`, lowercase platform, SOV ≠ SOH, `fp_*` vs scraped);
- the **full SQL template for the metric(s) the question names**, plus a compact
  index of every other metric;
- `dash.metric_catalog` rendered at plan time (cached for 15 minutes), so all
  57 Gold metrics are known without hardcoding them. Non-`computed` statuses
  (`proxy`, `partial`, `blocked`) keep their formula and missing-input note.

The catalog is capped at 4.5 kB and only named metrics get a full template. That
keeps the prompt under ~6 k tokens; Groq's free tier caps `openai/gpt-oss-120b`
at 8 k tokens per minute, and an untrimmed 33-template prompt was rejected with
HTTP 413.

**validate_sql** — `src/db/safe_sql.py` is the firewall. It:

1. rejects blocked keywords (`INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`,
   `CREATE`, `GRANT`, `REVOKE`, `TRUNCATE`, `COPY`, `EXECUTE`, `CALL`,
   `pg_sleep`, `pg_read_file`, `pg_ls_dir`, `lo_export`, `lo_import`, `dblink`);
2. rejects multiple statements (no `;` chaining);
3. parses the SQL with `sqlglot` and requires `SELECT`/`UNION`;
4. requires **every** referenced relation to be in the curated allowlist —
   the three Silver views plus a hand-picked set of `dash.*` tables, dimensions
   and views (`SILVER_RELATIONS | GOLD_TABLES | GOLD_DIMENSIONS | GOLD_VIEWS`).
   `silver.demo`, the base scraped tables, and the `app`/`ops`/`auth`/`storage`
   schemas are permanently excluded;
5. appends `LIMIT 200` if no limit is present.

**execute_sql** — `src/db/client.py` runs the query through a connection pool
whose connections are created with:

```
default_transaction_read_only=on
statement_timeout=10000   -- 10 seconds
```

So even if a bad query got past validation, it **cannot write** and cannot run
for more than 10 seconds. (Bulk index building uses a separate long-timeout,
still read-only, connection via `get_bulk_conn()`.)

**repair_sql** — if validation or execution fails, the error is sent back to the
LLM exactly **once**. After that the bot abstains.

**verify_numeric** — every number in the draft answer must appear in the query
results (0.5 % tolerance). If a number is ungrounded, the bot abstains instead
of showing it.

**zero_rows** — if the query is valid but returns nothing, the bot says
"No matching observations found" and shows the SQL it used. It does **not**
silently change the filters.

**sql_abstain** — handles three cases: unsupported metric, zero rows, or a
query that still fails after repair. Each gets a specific, honest message.

---

## 7. Stage 3b — the RAG path (DEFINITION)

`src/graph/rag_graph.py` is a CRAG-style self-healing loop:

```
retrieve → grade_relevance ─┬─► generate → verify_claims ─┬─► finalize
              ▲             │                              │
              └── rewrite_query ◄──────────────────────────┘
                            └─► abstain (after max 2 retries)
```

- **retrieve** — hybrid search (see §8). For `DEFINITION` questions it restricts
  retrieval to `doc_type` ∈ `{metric, documentation}`, so 3,813 data-row chunks
  cannot crowd out the documentation.
- **grade_relevance** — the critic LLM labels each chunk
  `relevant` / `ambiguous` / `irrelevant`; irrelevant chunks are dropped.
- **generate** — answers using **only** the retrieved chunks, and is told to
  cite `[source: file#section]`.
- **verify_claims** — splits the draft into claims and checks each against the
  chunks. Unsupported claims trigger a rewrite (max 2 retries) or an abstain.
- **finalize** — returns the draft plus a `sources` list like
  `metrics/status_vocabulary.md#Metric status vocabulary`.

**Honest caveat:** the generator and the critic are the same model family.
Self-critique is therefore *not independent proof*. That is exactly why the
retry limits, evidence-only generation, and abstain fallback exist. Do not
remove them.

---

## 8. The knowledge base and retrieval

### What is indexed

Chroma (persistent, `./chroma_db`, collection `sidnl_docs`) holds **3,910
documents**:

| Kind | Count | Built from |
|---|---|---|
| `data_rows` | 3,813 | chunks of 25 rows from the three Silver views |
| `metric` | 37 | one per metric in `metrics/metric_dictionary.yaml` |
| `documentation` | 60 | one per markdown heading in `metrics/*.md` and `docs/**/*.md` |

`metrics/gold_layer.md` is the newest documentation source: it explains the Gold
(`dash`) layer, OSA, SOH vs SOV, roll-up rules, first-party tables, serviceability
and freshness, and is what the DEFINITION path cites for Gold questions.

Embeddings: `intfloat/multilingual-e5-base`, computed locally (CPU). No API key
needed for embeddings.

### Unified metadata

Every chunk has the same three fields, which is what citations use:

```
source_file : "metrics/status_vocabulary.md" | "silver.v_latest_observation"
section     : heading / metric name / "rows 1-25"
doc_type    : "metric" | "documentation" | "data_rows"
```

`scripts/add_docs.py` backfills this metadata onto existing row chunks **without
re-embedding them** (about 30 seconds instead of a multi-hour rebuild).

### How search works

`src/retrieval/hybrid.py`:

1. **Vector search** — embed the query, ask Chroma for nearest chunks.
2. **BM25** — keyword search over the same corpus (good for exact metric names).
3. **Reciprocal Rank Fusion** — merge both ranked lists (`k = 60`), return the
   top `RETRIEVAL_TOP_K` (default 8).

Optional `doc_types` filtering applies to both searches. That is how the
DEFINITION path stays on documentation.

---

## 9. Guardrails at a glance

| Guardrail | Where | What it prevents |
|---|---|---|
| Route classification | `src/graph/router.py` | refusing a supported Gold KPI, or answering genuinely absent data (ETA/Instamart/JioMart/industry share) with a guess |
| SQL keyword blocklist | `src/db/safe_sql.py` | writes, DDL, file/system functions |
| Relation allowlist | `src/db/safe_sql.py` | reading `silver.demo`, base scraped tables, or non-curated `dash.*` relations |
| Single-statement rule | `src/db/safe_sql.py` | SQL injection via `;` |
| Auto `LIMIT 200` | `src/db/safe_sql.py` | accidental full-table dumps |
| Read-only transactions | `src/db/client.py` | any write at the database level |
| 10 s statement timeout | `src/db/client.py` | runaway LLM-generated queries |
| One repair attempt | `src/graph/sql_graph.py` | infinite retry loops |
| Numeric grounding check | `src/graph/sql_graph.py` | numbers not present in the rows |
| Zero-row abstention | `src/graph/sql_graph.py` | silently changing filters to force an answer |
| Gold catalog injection | `src/graph/sql_graph.py` | planner inventing a Gold formula or mislabelling a `proxy`/`partial` metric |
| Claim verification | `src/graph/rag_graph.py` | unsupported statements in definitions |
| Citation requirement | `src/graph/rag_graph.py` | answers with no traceable source |
| `router_error` field | `src/graph/router.py` + API | hiding provider outages as routing errors |

---

## 10. Evaluation

The eval harness lives in `eval/` and is run against the live API.

### Question set (`eval/questions.jsonl`) — 75 questions

| Route | Count | Notes |
|---|---|---|
| `NUMERIC` | 37 | 27 answerable, 8 are `expect_no_data` honesty tests, 2 adversarial |
| `DEFINITION` | 15 | must cite a source |
| `UNSUPPORTED` | 14 | must abstain, never produce a number |
| `AMBIGUOUS` | 9 | must ask a clarifying question |

Every SQL-bearing question has a `ground_truth_sql`, a `ground_truth_value`,
and an explicit `primary_column` (so the scorer compares the right metric, not
a row count).

### Metrics scored

| Metric | Question it answers |
|---|---|
| `route_correct` | did it take the right path? |
| `abstain_correct` | did it refuse exactly when it should? |
| `no_data_correct` | for known gaps, did it abstain instead of inventing? |
| `numeric_correct` | does the answer contain the ground-truth value? |
| `numeric_grounded` | is every number in the answer present in the rows? |
| `scope_stated` | does it state platform/city/time window? |
| `no_demo_leak` | did it ever mention `silver.demo`? |
| `sql_safe` | only allowlisted views, no write attempts? |
| `source_cited` | do DEFINITION answers cite a real file#section? |
| `retry_ok` | retries within the cap? |
| `hallucination` | any ungrounded number? |

### Current baseline (`reports/eval_baseline.md`)

| Metric | Score |
|---|---|
| route_correct | 89 % (97 % excluding three mislabelled adversarial questions) |
| no_data_correct | **100 % (8/8)** |
| no_demo_leak | 100 % |
| sql_safe | 100 % (34/34) |
| source_cited | 100 % (15/15) |
| hallucination | 0 |
| numeric_correct | **0/27 in the first run — root cause fixed and spot-checked; full re-run pending** (see below) |

The first baseline exposed a real bug: generated SQL used
`platform = 'Blinkit'`, but the data stores `'blinkit'`, so every numeric query
returned zero rows. The planner prompt now lists exact literals and product
matching rules. A six-question spot check after the fix passes (N26, N01, N34,
N07, N33, D03). A full re-run on the production model is still pending.

> **⚠️ The Gold rollout makes part of this baseline stale.** The eval set was
> written when only Silver was readable, so a number of its `UNSUPPORTED`
> questions (sales, revenue, SOV, SOH, ROAS, clicks, impressions) are now
> **answerable from the Gold layer**. Their `expect_abstain: true` flags and
> ground-truth SQL were left **unchanged on purpose** — the eval is the
> contract, and silently rewriting it to match new behaviour would hide the
> change. Treat those rows as known-stale expectations, not regressions. They
> should be re-labelled (route `NUMERIC`, real `ground_truth_sql`) once the Gold
> grants are in place and the numbers can be validated, then re-baselined.

> **Do not quote stability numbers from a run where the provider was rate
> limited.** A `429` makes the router fail safe to `AMBIGUOUS`, which looks like
> instability but is an infrastructure artifact.

### How to run it

```powershell
# API must be running first
.\.venv\Scripts\python.exe eval\run_eval.py --api-url http://127.0.0.1:8000 --timeout 240 --passes 1
.\.venv\Scripts\python.exe eval\rescore.py     # re-score stored results, no API calls
```

Use `--passes 1` until the provider quota is reliable; `--timeout 240` because
DEFINITION calls can take over 90 seconds.

Raw results go to `reports/eval_results.jsonl` (git-ignored). Markdown reports
in `reports/*.md` are committed as evidence.

---

## 11. How to run everything

All commands are run from the `Rag/` directory with the project venv.

### First-time setup

```powershell
cd Rag
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -e ".[dev]"
copy .env.example .env
# edit .env: set DATABASE_URL and the LLM_* values
```

`.env` is git-ignored. **Never print or commit it.**

### Environment variables (`.env`)

| Variable | Purpose |
|---|---|
| `DATABASE_URL` | read-only Postgres/Supabase connection string |
| `LLM_PROVIDER` | `openai` or `groq` |
| `LLM_API_KEY` | provider key |
| `LLM_API_BASE` | e.g. `https://api.groq.com/openai/v1` |
| `LLM_GENERATOR_MODEL` | model that writes answers |
| `LLM_CRITIC_MODEL` | model that grades/verifies |
| `LLM_ROUTER_MODEL` | model that classifies questions |
| `EMBEDDING_MODEL` | local sentence-transformers model |
| `CHROMA_PERSIST_DIR` / `CHROMA_COLLECTION_NAME` | index location |
| `RETRIEVAL_TOP_K` | chunks returned (default 8) |
| `MAX_RETRIES` | RAG rewrite cap (default 2) |
| `DOCS_DIR` | markdown corpus for DEFINITION questions |
| `API_HOST` / `API_PORT` / `LOG_LEVEL` | server settings |

Current deployment uses Groq with `openai/gpt-oss-120b` for all three LLM roles
(the OpenAI account has no credits). Any OpenAI-compatible provider works.

### Database access (one-time, run as the `postgres` owner)

The chatbot connects with a **read-only** role (`sidnl_chatbot_app`). That role
needs `USAGE` + `SELECT` on **both** `silver` and `dash`. Without the Gold grant
every KPI query fails with `permission denied for schema dash`.

```powershell
# as the postgres owner, against the same database as DATABASE_URL
psql "$SUPABASE_DB_URL" -f sql\04_gold_access.sql
```

`sql/04_gold_access.sql` is safe to re-run. It:

1. grants `USAGE` on `silver` and `dash`;
2. grants `SELECT ON ALL TABLES IN SCHEMA` for both schemas;
3. sets `ALTER DEFAULT PRIVILEGES FOR ROLE postgres` so future Gold tables are
   readable without another manual grant;
4. creates the safety view `dash.v_chatbot_availability_city` (city totals only);
5. re-asserts read-only defaults and the 10 s statement timeout;
6. ends with verification queries.

`sql/03_roles.sql` is the fuller, canonical version of the same grants (plus
revokes on `public`/`app`/`ops`/`auth`/`storage`). The database grant is
deliberately broad; the real guardrail is the curated allowlist in
`src/db/safe_sql.py`.

Verify after running it:

```sql
select count(*) from dash.metric_catalog;               -- expect 57
select count(*) from dash.v_chatbot_availability_city;  -- city-total rows only
```

### Verify the install

```powershell
.\.venv\Scripts\python.exe -m pytest -q          # 83 tests
.\.venv\Scripts\python.exe -m compileall -q src eval scripts tests
```

### Build or refresh the index

```powershell
.\.venv\Scripts\python.exe scripts\add_docs.py      # docs only, ~30 s, keeps row embeddings
.\.venv\Scripts\python.exe scripts\build_index.py   # full rebuild, ~5.5 h on CPU
```

`build_index.py` writes in batches and caches embeddings in
`reports/embed_cache/rows-<fingerprint>.npy`, so a re-run with unchanged data
skips the expensive encode.

### Start the API

```powershell
.\.venv\Scripts\python.exe -m uvicorn api.app:app --app-dir src --port 8000
```

Then:

```powershell
curl http://127.0.0.1:8000/health
curl -X POST http://127.0.0.1:8000/chat -H "Content-Type: application/json" -d "{\"question\":\"What is the in-stock rate for Mr. Munchies on Blinkit?\"}"
```

Interactive docs are at `http://127.0.0.1:8000/docs`.

### Other useful scripts

| Script | Purpose |
|---|---|
| `scripts/profile_data.py` | Stage A data profiler |
| `scripts/run_ground_truth.py` | capture ground-truth values for eval questions |
| `eval/rescore.py` | re-score saved results without calling the API |

---

## 12. Repository map

```
Rag/
├── src/
│   ├── config.py              all settings from .env
│   ├── api/app.py             FastAPI /health and /chat
│   ├── graph/
│   │   ├── main_graph.py      top-level router → subgraph wiring
│   │   ├── router.py          LLM question classification (+ keyword override)
│   │   ├── sql_graph.py       NUMERIC path (Silver + Gold, catalog loader)
│   │   ├── rag_graph.py       DEFINITION path
│   │   ├── prompt_utils.py    safe template rendering (handles literal JSON)
│   │   └── state.py           shared ChatState schema
│   ├── db/
│   │   ├── safe_sql.py        SQL firewall / Silver+Gold allowlist / LIMIT injection
│   │   └── client.py          read-only pool, 10 s timeout, bulk connection
│   ├── retrieval/
│   │   ├── hybrid.py          Chroma + BM25 + RRF
│   │   └── docs_index.py      documentation chunking and indexing
│   └── prompts/               all LLM prompts as markdown
├── scripts/                   index builders, profiler, ground truth
├── eval/                      questions.jsonl, run_eval.py, rescore.py
├── metrics/                   metric_dictionary.yaml, status_vocabulary.md,
│                              gold_layer.md (Gold definitions for DEFINITION Qs)
├── reports/                   committed markdown evidence (bulk output ignored)
├── tests/                     83 tests
└── sql/                       reference SQL
    ├── 01_views.sql           Silver views + Gold map + availability_city view
    ├── 03_roles.sql           canonical Silver+Gold grants, revokes, timeouts
    └── 04_gold_access.sql     safe, re-runnable script for the owner to unblock Gold
```

---

## 13. Troubleshooting and known limitations

**The bot says "No matching observations found" for a question that should work.**
Check the generated SQL (`sql` field) for:
- `platform = 'Blinkit'` instead of `'blinkit'` (case-sensitive);
- `city = 'Bangalore'` instead of `'Bengaluru'`;
- exact `product_name = '...'` instead of `ILIKE '%...%'`;
- filters the question did not ask for (`availability = true`, extra brand).

**A full index rebuild exits non-zero with a Chroma "compaction" error.**
The write usually succeeded. Verify before rebuilding:

```python
col.count()            # should be 3,910
col.get(limit=3)       # returns ids + metadata + documents
col.query(...)         # returns hits
```

If those work, the index is fine and the error is cosmetic. Do not re-embed.

**Answers are slow (60–90 s) on DEFINITION questions.**
The RAG path makes several LLM calls (grade each chunk, generate, verify).
Reducing `RETRIEVAL_TOP_K` lowers the number of grading calls.

**Everything suddenly routes to AMBIGUOUS.**
Check the `router_error` field. A `429` from the provider means the daily token
quota is exhausted; the router fails safe. Wait for the quota to reset, or
switch models in `.env`.

**Numbers are wrong but the SQL looks right.**
Check `metric_status`:
- `gold` — computed by the Gold (`dash`) layer; `dash.metric_catalog` holds the
  authoritative formula. If the catalog status is `proxy` / `partial` /
  `blocked`, the number is not the final KPI and `missing_inputs` says why.
- `draft` — usable but flagged with a banner; the definition may still change.
- `unsupported` — must not be answered with SQL.

**Every Gold query fails with `permission denied for schema dash`.**
The read-only role has no `USAGE` on `dash` yet. Run
`sql/04_gold_access.sql` as the `postgres` owner (see §11), then confirm
`select count(*) from dash.metric_catalog;` returns 57. Until then the planner
still works (it falls back to the Gold relation map) but execution cannot read
Gold.

**A numeric question fails with HTTP 413 / "Request too large".**
The planner prompt exceeded the provider's per-minute token cap. On Groq's free
tier `openai/gpt-oss-120b` is limited to 8 k TPM. The prompt is now trimmed: only
the metric(s) the question names get a full SQL template, and the Gold catalog is
capped at 4.5 kB. If it recurs, lower `_GOLD_CATALOG_CHAR_BUDGET` or the
`template_chars` / `max_full` arguments in `_build_metric_templates_text`.

**Server will not start / port in use.**

```powershell
Get-NetTCPConnection -LocalPort 8000 -State Listen
Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
  Where-Object { $_.CommandLine -like '*uvicorn*' }
```

**A file edit truncated to 0 bytes.**
Check free disk space first; a full disk can make editors fail mid-write.

**Security note.** Rotate the LLM API key and the database role password if they
have ever appeared in chat logs or terminal output. Keep `.env` out of git
(`git check-ignore .env` should print the path).

### Known limitations

- Coverage is narrow by design (see §2). Most "why can't it answer X?" questions
  are coverage gaps, not bugs.
- The critic and generator share a model family, so self-verification is a
  quality check, not proof.
- `delivery_eta_minutes` is 100 % NULL and is never used.
- **Gold reads are pending a one-time grant.** `sql/04_gold_access.sql` must be
  run by the database owner; until then every `dash.*` query returns
  `permission denied for schema dash`.
- **The eval expectations for sales / revenue / SOV / SOH / ROAS / clicks /
  impressions are stale.** They were written for a Silver-only bot and are still
  marked `expect_abstain`. They were deliberately not rewritten; re-label and
  re-baseline after the Gold grant lands.
- `N16`, `N25`, `N30` in the eval set are answerable but route to `UNSUPPORTED`
  under the old routing; the router override that caused this has been removed,
  so a re-run should fix them.
- The full 75-question eval has not yet been re-run on the production model
  after the planner and Gold changes (Groq daily-token quota).
- Genuinely unavailable, and correctly refused: delivery ETA, Instamart,
  JioMart, industry market share / total category size.

---

## 14. Open questions

See `OPEN_QUESTIONS.md` for the authoritative list. The main ones:

- Should NULL `availability` be a separate bucket ("unknown") or excluded?
- Confirm `observed_in_stock_rate` and `avg_discount_pct` definitions with the
  analytics mentor before marking them `approved`.
- **Share of Shelf (SOH) vs Share of Voice (SOV):** both now have a Gold
  definition (`metrics/gold_layer.md`) and a formula in `dash.metric_catalog`.
  What still needs sign-off is whether those are the *company* definitions, and
  whether brand-level SOV should include keyword campaigns or category shelf
  only.
- **Gold `proxy` / `partial` metrics:** several `dash.metric_catalog` rows are
  proxies or have missing inputs. Each needs an owner decision on whether to
  publish them as-is or wait for the missing feed.
- **Eval re-baseline:** which of the old `UNSUPPORTED` expectations should
  become `NUMERIC` Gold questions, and what ground-truth SQL each should use.
- Cross-platform product matching is not built, so cross-platform price
  comparison across *different* SKUs is unsupported. (Gold
  `v_comp_cross_marketplace` compares the same SIDNL id on two platforms.)
