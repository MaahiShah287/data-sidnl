# Task: consolidate the `data-sidnl` code base to ~12 files, finish the automation, change no logic

You are working in the SIDNL repo (github.com/MaahiShah287/data-sidnl), folder `data-sidnl/` only (**not** `Rag/`).
The live system is Supabase project `jqxnaqbvwgmfkyzfincy`. The database is the source of truth; the repo must
describe it exactly, in as few files as possible. Facts below were verified against the live database on 2026-11-10;
**re-verify every fact in Phase 0 before relying on it.**

## 0. Hard rules (never break)
1. **No invented data.** No demo, sample or fake rows in any table or file. Numbers come only from bronze.
   "Bronze" = every schema except `silver` and `dash` (today: `public.*`; `ecomscraper` is empty). Bronze is **read-only**.
2. **No logic change.** Every function, view, trigger, cron job, threshold and fallback must behave exactly as now.
   Consolidation moves and generates text; it does not rewrite behaviour. Never change SI-id logic
   (`silver.resequence_sidnl`, A-Z ordering) or the matcher rules.
3. **Production changes only via Supabase migrations** (`apply_migration`), named `silver_NNN_slug` / `dash_NNN_slug`,
   each first run as a **dry run inside a transaction that is rolled back** (end the script with
   `do $$ begin raise exception 'R %', <results>; end $$;`), each with a rollback, each followed by a check that the
   stored statement md5 (`md5(array_to_string(statements, E'\n'))` in `supabase_migrations.schema_migrations`) equals
   the md5 of the file in the repo. Never re-apply an old migration.
4. **Fault tests change behaviour, never data**: inject faults with a trigger or a replaced function inside a rolled-back
   transaction. Afterwards prove the database is unchanged (row counts, `cron.job` active flags, function md5s).
5. **Secrets** (Slack webhook, email keys, service-role key) go only into Supabase Vault / edge-function secrets.
   If one is needed, **stop and ask the owner**. Never print, commit or log one.
6. **Git**: commit straight to `main` in small steps and push to `origin main` (owner's standing preference; no feature
   branches). Before each commit, `git fetch` and fast-forward; if `origin/main` moved, rebase your commits on top
   (never force-push), and do not delete or rewrite a teammate's files without the owner's OK.
7. If anything is unclear, irreversible, or would change a number on the front end, **stop and ask**.

## 1. What is live (the logic you must preserve)
**Layers:** bronze `public.*` → `silver` (cleaned facts + canonical products) → `dash` (front-end tables, "gold").
**Keys:** facts carry the stable `product_key`; `silver.product_xref` maps each product to its `sidnl_id`. SI ids are
renumbered A-Z by name by the pipeline, so they are **never** copied into silver fact tables. `dash.*` is rebuilt from
silver on every gold refresh (`gold_visibility_days = NULL` → full visibility rebuild; required because SI ids move).

**10 pg_cron jobs (all must keep running, same schedules):**
| job | schedule | does |
|---|---|---|
| `sidnl-pipeline` | every minute | `silver.run_tick()` → `run_pipeline` (discover, load brands, load category shelves, map products, sync canonicals, resequence SI ids, quality gate, watermarks) with job queue, retry 2/4/8/16 min, permanent vs transient errors |
| `sidnl-pipeline-daily` | 18:35 UTC | `silver.enqueue_daily()` forced full run |
| `sidnl-gold` | every minute | `silver.run_gold_pending()` → `dash.sync_dims()` + `dash.refresh()`; failure = gold `failed` + backoff, last good dash kept, timeout caught (Gap 1) |
| `sidnl-auto-match` | */10 min | `silver.auto_approve_exact_matches()`: only exact cross-platform twins (brand + normalized name + parsed size/unit/pack); fuzzy never auto-merged |
| `sidnl-store-city` | */10 min | `silver.fill_store_cities()`: city-less store gets the single city all its bronze snapshots record; logged in `ops.store_city_filled` |
| `sidnl-freshness` | */5 min | `silver.refresh_freshness()`: bronze freshness per platform × source, id cursor (Gap 2) |
| `sidnl-dead-letter` | */15 min | `silver.retry_dead_letters()` (Gap 3) |
| `sidnl-maintenance` | 19:05 UTC | `silver.run_maintenance()`: purge `cron.job_run_details` > 14 days, analyze tables without stats |
| `sidnl-reconcile` | 19:20 UTC | `silver.reconcile()`: every reading/shelf fact vs its bronze row; dash vs an independent re-aggregation of silver; logs `ops.reconciliation_log` |
| `sidnl-reconcile-coverage` | 19:40 UTC | `silver.reconcile_coverage()`: every bronze shelf row up to its scope watermark is in silver or in `ops.dead_letter` |

**Fallbacks already built:** Gap 1 `dash_006` + `dash_007`; Gap 2 `silver_062`; Gap 3 `silver_063` (category loader
chunk body in `silver.load_category_chunk`, bisection in `silver.load_category_range`, cap 100 rows/chunk → scope fails,
transient errors re-raised). Also live: `silver_056` (pack parser), `silver_057` (seen dates), `silver_058` (auto-match),
`silver_059` (maintenance), `silver_060` (store city), `silver_061` (reconciliation), `dash_008/009` (brand scorecard).

**Live objects (re-dump in Phase 0):** `silver` 21 tables, 19 views, 70 functions, composite types `silver.pack_t`,
`silver.match_feat`; `dash` 19 tables, 6 views, 2 functions; `ops` 16 tables, 11 views. Config lives in
`silver.sidnl_config`, `silver.freshness_policy`, `dash.cfg_threshold`, `ops.freshness_override`.

**Consumers you must not break:**
- `portal/` (Next.js) reads `dash.availability`, `dash.pricing`, `dash.visibility`, `dash.dim_sidnl`, `dash.dim_city`,
  `dash.overview`, `dash.supply`, `dash.ads`, `dash.refresh_state` through a server-side pool.
- `Rag/` (out of scope, but its queries hit the DB) reads `silver.v_latest_observation`, `silver.v_latest_shelf_position`,
  `silver.v_all_platforms`, `silver.blinkit`, `silver.zepto`, `silver.instamart`, `silver.jiomart`. **Do not drop or
  rename these.** (Rag also references `silver.demo`, which no longer exists; report it to the owner, do not recreate it.)

## 2. What is in the folder today (174 tracked files) and what happens to each
| Path | Files | Verdict | Why |
|---|---|---|---|
| `sql/001_schema.sql`, `002_pipeline.sql`, `003_dynamic_matching.sql` | 3 | **delete** | build schema `sidnl.*`, which does not exist in Supabase |
| `sql/gold/**` | 18 | **delete** | target schema `gold`, retired by `dash_004`/`dash_005` |
| `sql/silver/0NN_*.sql` (numbered history) | ~30 | **replace** by the generated baseline (§3) | history only; README already says "not safe to re-apply"; exact applied text is in `supabase_migrations.schema_migrations` |
| `sql/silver/live/*.sql`, `sql/dash/live/*.sql` | 26 | **replace** by baseline + manifest | same content is stored in `schema_migrations`; the manifest keeps version/name/md5 |
| `sql/silver/0NN_rollback.sql`, `sql/dash/0NN_rollback.sql`, `004_rollback.md` | ~20 | **merge** into `sql/rollbacks.sql`, one labelled section per migration, text unchanged | keeps every rollback |
| `sql/silver/drafts/**` (incl. `unapplied_b314c08/`) | 14 | **delete after** Gap 4/5 are built from them (§4); never applied | |
| `sql/dash/evidence/*`, `sql/silver/evidence/*`, `ledger_verify.sql`, `verify_repo_parity.py`, `LIVE_MIGRATION_MANIFEST.csv`, `MIGRATION_LEDGER.md`, `sql/*/README.md` | ~10 | **merge** into `sql/manifest.csv` + `sidnl.py verify` + `docs/ARCHITECTURE.md` | |
| `sidnl/ingest.py`, `loader.py`, `match.py`, `normalize.py`, `rules.py`, `stream.py` | 6 | **delete** | read/write schema `sidnl.*` (does not exist); the CLI never calls them; their logic now lives in SQL (`silver.parse_pack`, `silver.score_pair`, `silver.map_product`, ...) with in-DB self-tests |
| `tests/test_logic.py` | 1 | **delete** | only tests the six dead modules; the live logic is covered by `silver.selftest_parser()`, `silver.selftest_matcher()`, `silver.quality_checks()` |
| `config/matching.yaml`, `config/platforms.yaml` | 2 | **delete** | read only by the dead modules / dead test; live config is in DB tables |
| `crontab.txt`, `deploy/sidnl-live.service`, `landing/`, `logs/` | 4 | **delete** | call CLI commands that no longer exist (`daily`, `learn`, `live`); scheduling is pg_cron |
| `sidnl/__init__.py`, `cli.py`, `common.py`, `silver.py` | 4 | **merge** into one `sidnl.py` (run as `python sidnl.py ...`) | ~110 lines total |
| `tests/test_silver_sql.py` | 1 | **merge** into `tests/test_live_db.py` | |
| `README.md`, `REVIEW.md`, `docs/**/*.md` (11 md) | 12 | **merge** into `README.md` + `docs/ARCHITECTURE.md` | keep facts, drop dated audit narration (keep a short "history" section with migration names + one line each) |
| `docs/silver/erd.mmd/.png/.svg` | 3 | **merge**: mermaid source inline in `ARCHITECTURE.md`, regenerated from the live schema | |
| `requirements.txt` | 1 | **keep, trim** to `psycopg[binary]>=3.2` (pandas, pyarrow, pyyaml, rapidfuzz were for the dead modules) | |
| `edge-functions/alert-dispatch/index.ts`, `edge-functions/heartbeat/index.ts` | 2 | **keep, fix, deploy** (§4) | Supabase needs one folder per function |
| `portal/**` | 16 | **out of the file-count target** (separate Next.js app); only change what §4.3 says | |
| `.gitignore` | 1 | keep | |

## 3. Target layout (12 files + the 2 edge functions)
```
data-sidnl/
  README.md                  what it is, how data flows, every cron job, how to operate, runbook "if X breaks, do Y"
  docs/ARCHITECTURE.md       schemas, lineage, keys, metric definitions, canonical mapping rules, fallbacks 1-5,
                             reconciliation, ERD (mermaid), decisions log, short migration history
  sql/01_silver.sql          GENERATED from live: silver types, tables, indexes, constraints, functions, views, config rows
  sql/02_dash.sql            GENERATED from live: dash tables, functions, views, config rows (cfg_threshold, cfg_sku)
  sql/03_ops_and_cron.sql    GENERATED from live: ops tables/views/functions, triggers, cron.schedule(...) for all jobs
  sql/rollbacks.sql          every rollback, one section per migration:  -- == <version> <name> ==
  sql/manifest.csv           version,name,md5 for every row of supabase_migrations.schema_migrations
  sidnl.py                   CLI: report | run | refresh | test | verify | export-schema   (one file)
  tests/test_live_db.py      unittest, skipped without SUPABASE_DB_URL; smoke + all fallback scenarios (§5)
  requirements.txt
  CONSOLIDATION_PROMPT.md    (this file; delete it in the last commit)
  .gitignore
  edge-functions/alert-dispatch/index.ts
  edge-functions/heartbeat/index.ts
```
**Generated means generated.** `python sidnl.py export-schema` writes `sql/01..03` from the live catalog, never by hand:
`pg_get_functiondef` for every function, `pg_get_viewdef` for every view (`create or replace view ... with (security_invoker = true)`
where set), table DDL from `pg_attribute`/`pg_constraint`/`pg_indexes` (generated columns, defaults, FKs, partial indexes,
RLS enabled), composite types, `comment on`, config rows from the config tables only (`silver.sidnl_config`,
`silver.freshness_policy`, `silver.ref_noise_word`, `silver.ref_variant_synonym`, `dash.cfg_threshold`, `dash.cfg_sku`,
`ops.freshness_override`), and `cron.schedule('<name>', '<schedule>', $$<command>$$)` for each job. **No fact, dimension,
canonical, xref, log or bronze rows.** Objects are ordered by dependency (types → tables → functions → views → triggers → cron).
Header of each file: generated-at, project ref, and "documentation / recovery baseline - never apply to production".
`python sidnl.py verify` regenerates in memory and diffs against the files, compares md5 of every function and view with
the live catalog, compares `sql/manifest.csv` with `schema_migrations`, and exits non-zero on any difference.

**New-change workflow (write it into README):** write `silver_NNN_slug` → dry run (rolled back) → `apply_migration` →
md5 check → append its rollback section to `sql/rollbacks.sql` → `python sidnl.py export-schema` → `python sidnl.py verify`
→ commit. The repo never grows by one file per migration again.

## 4. Finish the automation (built on the existing drafts, logic additive)
### 4.1 Gap 4: alert delivery
Use `sql/silver/drafts/unapplied_b314c08/20261110130000_silver_065_alert_outbox.sql` as the starting point, but **fix it**:
its trigger `ops.alert_log_to_outbox()` reads `new.severity/new.title/new.details/new.message`; `ops.cron_alert_log` has
`alert_id, jobname, level, consecutive_failures, last_failure_message, alerted_at` and `ops.storage_alert_log` has
`alert_id, level, used_pct, message, ...` (re-check). Use one trigger function per table (or `to_jsonb(new)` lookups) so an
insert into a log table can never fail because of the outbox. Dedupe key `<table>:<alert_id>`. Sources already writing
alert rows: cron failures (`check_cron_alert`), storage, `freshness:<platform>/<source>`, `sidnl-reconcile:data`,
`sidnl-reconcile:coverage`, `dead-letter:<scope>`. Delivery is via edge function `alert-dispatch` (claim → POST →
mark; at-most-once on a crash; backoff `silver.backoff_minutes`; `dead` after `alert_max_attempts`), switched off by
`sidnl_config.alert_delivery_enabled = 0` until the owner sets the Slack secret. Ask the owner before enabling pg_net and
before scheduling `sidnl-alerts`. Test with a local HTTP receiver (200 → `sent` once, re-run → no duplicate; 500/timeout →
`pending` with backoff, then `dead`); nothing fake is written to the database.
### 4.2 Gap 5: heartbeat
Use `drafts/unapplied_b314c08/20261110124500_silver_064_heartbeat.sql` + `edge-functions/heartbeat/index.ts`. Re-check its
config keys and view names against what is live. `ops.v_heartbeat`: one row per `sidnl-%` job (overdue if last start older
than its interval × 2 + margin, or `active = false`), plus "bronze advanced but no pipeline run started within N minutes",
plus oldest pending outbox row. The edge function returns 200 / 503 (also 503 if the DB is unreachable), exposes no data
beyond job names, ages and ok/overdue. The `enqueue_daily_safe` wrapper (lock_timeout so the 18:35 daily job no longer
times out while `run_tick` holds the same daily row) needs the owner's OK to change the `sidnl-pipeline-daily` command.
Tell the owner exactly what to set up outside Supabase: an uptime monitor polling the heartbeat URL every 5 min.
### 4.3 Front end
In `portal/src/lib/db.ts` replace the header `freshness()` query (max `refreshed_at` + `refresh_state.last_error`) with
`dash.v_refresh_status` (last refreshed, `is_stale`, `refresh_failing`) and `dash.v_platform_freshness` (per-platform
"data stale since ..." banner). Optional: a brand page reading `dash.v_brand_scorecard_latest`. Show `NULL` as "not measured",
never as 0.
### 4.4 Optional DB tidy (only with proof, one migration each)
Candidates: `silver.v_wide`, `silver.v_data_freshness` (superseded by `dash.v_data_freshness`), `silver.refresh_all`,
`silver.ref_metric_support`, `dash.metric_catalog`, `dash.dim_date`, `ops.backup_silver_057` (rollback data for 057),
old `ops.function_backup` rows. Drop one only if `pg_depend`, every function body, `portal/` and `Rag/` show no use, with a
rollback that recreates it from the generated baseline. **Never drop** the Rag views or the dash tables the portal reads
(including the empty `overview`/`supply`/`ads`).

## 5. Tests (`tests/test_live_db.py`) — real data, faults injected in rolled-back transactions
Smoke: `silver.selftest_parser()`, `silver.selftest_matcher()`, `silver.quality_checks()` all pass; every product has an SI id.
Fallback scenarios (record how injected, expected, actual, and proof the DB is unchanged):
1 transient error in a Silver step → retry 2/4/8/16; 2 permanent error → not retried, alert row; 3 quality gate blocks one
scope only, watermark holds; 4 overlapping runs → advisory lock skip; 5 missed cron → daily catch-up (cron timing itself:
"not tested" without a Supabase branch); 6 `dash.refresh` fails → gold failed, backoff, old dash intact, recovers (timeout too);
7 `dash.sync_dims` fails → same; 8 Silver run fails → no gold refresh; 9 platform stale via lowered threshold → stale + event +
alert, clears after; 10 bad rows → dead-lettered, batch loads, retry resolves, cap and transient paths; 11 three cron failures
→ one outbox row, one delivery; 12 alert endpoint down → backoff, no data impact; 13 paused job → heartbeat overdue.
Plus: `silver.reconcile()` and `silver.reconcile_coverage()` return 0 mismatches.

## 6. Phases and gates
- **Phase 0 (read-only):** re-dump the live inventory (§1), check every claim in §2 (grep the repo, `pg_depend`, function
  bodies, portal, Rag). Write a short note of anything that differs. **Stop and show the owner.**
- **Phase 1:** build `sidnl.py export-schema` + `verify`; generate `sql/01..03`, `sql/manifest.csv`, `sql/rollbacks.sql`;
  `verify` must pass against live. Commit.
- **Phase 2:** delete/merge files per §2 in small commits; after each, `python sidnl.py verify` passes and
  `tests/test_live_db.py` passes. No database change in this phase.
- **Phase 3:** Gap 4 and Gap 5 (§4.1, §4.2) as migrations with dry runs; stop for secrets / pg_net / cron-command approvals.
- **Phase 4:** portal change (§4.3), optional tidy (§4.4) only with proof.
- **Phase 5:** run all tests and both reconciliations, update README runbook with only tested behaviour, delete this
  prompt file, push.

## 7. Done means
- `data-sidnl/` (excluding `portal/`) has at most 12 files plus the two edge functions; `Rag/` untouched.
- `python sidnl.py verify` passes: every live function/view md5 matches the repo, manifest matches `schema_migrations`.
- All 10 (or more) cron jobs active and green for an hour after the last change; `ops.v_reconciliation_latest` all `ok`,
  0 mismatches; `ops.v_dead_letter_summary` has no unexplained open rows; `dash.v_refresh_status` not stale.
- Every front-end number still traces to bronze (reconcile passes); nothing was invented; no secret in the repo.
- Final report to the owner: files before → after, migrations applied (version, name, md5), test table, what was not
  tested and why, and what the owner must do outside the repo (Slack secret, pg_net approval, uptime monitor URL).
