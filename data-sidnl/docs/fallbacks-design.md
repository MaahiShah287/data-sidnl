# Fallback mechanisms for Silver and Gold: audit and design

Status: **DRAFT, waiting for approval** (Phase 1 gate). Nothing in this document has been applied to the database.
Audit date: 2026-11-10, against the live project `jqxnaqbvwgmfkyzfincy`. Everything below was read from the live
catalog (`pg_get_functiondef`, `cron.job`, `information_schema`), not from the repo copies.

---

## 0. Phase 0 audit

### 0.1 What matches the brief
- Cron: `sidnl-pipeline` (jobid 1, every minute, `set statement_timeout='600s'; select silver.run_tick()`),
  `sidnl-pipeline-daily` (jobid 2, `35 18 * * *`, `select silver.enqueue_daily('cron-daily', false)`),
  `sidnl-gold` (jobid 6, every minute, `set statement_timeout='600s'; select silver.run_gold_pending()`). All active.
- `silver.run_gold_pending()` works as described: try-lock 727101; picks the latest `status='success'` run with
  `gold_status='pending'`, or `'failed'` with `gold_next_at <= now()`; marks older pending rows `superseded`; runs
  `dash.sync_dims()` then `dash.refresh(3)`. **Confirmed gap:** a `dash.refresh` error is caught in an inner block, written to
  `dash.refresh_state('last_error')`, and the run is still marked `gold_status='success'`, so it is never retried.
- `silver.classify_error`: SQLSTATE classes `22, 23, 42, 0A, 2B, 44, 0L, 28` are permanent, everything else transient.
  `silver.backoff_minutes`: 2/4/8/16 (16 for attempt 4 and above). Silver job max attempts come from `ops.pipeline_job.max_attempts`.
  The Gold limit of 5 is a literal `5` inside `run_gold_pending`.
- `silver.run_pipeline` takes try-lock 727100. Any step failure makes the run `partial`, and a quality-gate block makes it
  `blocked`. Only `success` sets `gold_status='pending'`; every other status sets `gold_status='skipped'`. So **Silver ->
  Gold isolation is already enforced** (this covers scenario 8).
- Watermarks: shelf sources and category scopes advance only when their own steps succeeded and were not blocked;
  blocked scopes get `category_scope.last_status='blocked'`.
- Alerts are only logged: `silver.check_storage_alert()` writes `ops.storage_alert_log`, and `silver.check_cron_alert()`
  writes `ops.cron_alert_log` (threshold `sidnl_config.cron_alert_consecutive_failures = 3`, re-alerts after 1 day,
  writes a `recovered` row). Both are called from `silver.record_storage_snapshot()`, which `run_tick` calls every
  minute inside `begin … exception when others then null`. Both log tables are **empty** today.

### 0.2 `dash.refresh`: does a failure keep the last good snapshot? **Yes.**
- `dash.refresh` rebuilds `dash.pricing` and `dash.availability` with **delete all + insert**, and `dash.visibility` with
  **delete last N days + insert**, all inside the one transaction of the calling cron statement. It does not truncate or swap tables.
- `run_gold_pending` calls it inside a `begin … exception` block, which is a savepoint. On error that block rolls back,
  so readers (MVCC) keep seeing the previous committed rows. A failure never leaves a half-empty table visible.
- `dash.sync_dims()` uses upserts, except for `dash.dim_sidnl`, which it rebuilds with delete + insert. It runs in the same
  transaction and is just as atomic.
- `dash.overview`, `dash.supply` and `dash.ads` have 0 rows. `dash.refresh` declares them but does not fill them (they wait
  for sales, retail-media and ERP feeds). The live row counts are `pricing` 1,252, `availability` 50,604, `visibility` 39,474,
  `dim_product` 7,149 and `dim_sidnl` 7,141.
- **Residual risk:** a `statement_timeout` (SQLSTATE 57014) is **not** caught by `when others` in PL/pgSQL. If the
  refresh times out, the whole cron statement aborts, `gold_status` stays `pending`, and the run is retried every minute
  with no backoff and no recorded attempt. The design below handles this with an explicit `when query_canceled` handler.

### 0.3 Bronze freshness sources (real values, 2026-11-10 ~09:40 UTC)
| Source table | Time column | Platform from | Latest row per platform |
|---|---|---|---|
| `public.shelf_snapshots` | `taken_at` | `platform` | blinkit 2026-11-10 06:19 (2,167 rows in the last 24h) |
| `public.search_snapshots` | `taken_at` | `platform` | blinkit 2026-11-08 06:30, zepto 2026-11-08 06:49 |
| `public.observations` | `observed_at` | `listing_id -> platform_listings.platform` | blinkit 2026-11-08 06:32, zepto 2026-10-30 15:44, demo 2026-10-26 |

`instamart` and `jiomart` are registered in `silver.dim_platform` but have **no rows** in any source. Rows marked
`demo` (`is_test=true`) exist in bronze. They are excluded from dash and will be excluded from freshness.

### 0.4 Contradictions with the brief and other findings
1. **Repo layout differs.** There is no `supabase/migrations/`, no `supabase/rollbacks/` and no `docs/runbook.md`. The repo
   puts exact applied SQL in `sql/silver/live/<timestamp>_<name>.sql` and rollbacks next to it as `sql/silver/NNN_rollback.sql`
   (and `sql/dash/NNN_rollback.sql`). The operations doc is `docs/silver/SILVER_OPERATIONS.md`. *Decision needed (Q1).*
2. **`ecomscraper` has no tables.** The schema exists but is empty. Bronze is only `public.*`.
3. **No pg_net.** Installed extensions: plpgsql, pg_stat_statements, uuid-ossp, pgcrypto, supabase_vault, pg_trgm, pg_cron.
   Vault has 0 secrets. The only edge function is `request-demo`.
4. **No Supabase branches exist.** Creating one is a paid resource. *Decision needed (Q2).*
5. **The daily cron job failed last night (2026-11-09 18:35 UTC)** with `canceling statement due to statement timeout … while
   inserting index tuple … pipeline_job`. Cause: at 18:35 `run_tick` had already inserted today's daily job through
   `enqueue_daily('catchup', true)` (job 3527) and was still running the pipeline in that same transaction. The `cron-daily`
   insert then waited on the unique index `pipeline_job_daily_uq` until it timed out. The forced daily run **did happen**
   (job 3527, success), but the `sidnl-pipeline-daily` job shows as failed. This recurs on any night the 18:35 tick runs long.
   It counts toward cron alerts, but cannot reach 3 consecutive failures on a daily job within a day. The fix is in Gap 5.
6. **History of permanent failures:** 551 regular jobs failed permanently on 2026-11-09 (`23502 null brand_name in
   brand_scope`, fixed by `silver_048`), and the 2026-11-09 daily job failed for the same reason. Today all fact rows are
   `dq_status='valid'` (56,249 readings, 1,832,098 shelf rows), so **no rejected rows exist to dead-letter today**.
7. The loaders (`refresh_brand`, `refresh_category_scope`, `refresh_category_products`) are set-based with no per-row error
   handling. One bad row raises for the whole brand or scope, which is exactly the 551-failure incident. Category scopes
   are isolated per scope (`refresh_category_market` has a per-scope `exception` block); brands are isolated per brand in
   `run_pipeline`.
8. Local test baseline: `python -m unittest discover -s tests` shows `test_logic` erroring on `ModuleNotFoundError: yaml`
   (a local environment problem, not caused by this work) and both SQL smoke tests skipped because `SUPABASE_DB_URL` is not set in this
   shell. DB checks in this work run through the Supabase MCP connection.

---

## 1. Principles used by every gap
- **Additive.** New tables, views, functions and cron jobs only. No existing column, view contract or SI id logic changes.
  The **one exception** is `silver.run_gold_pending()`, which must be replaced (`create or replace`, same signature
  and return shape) to close Gap 1. Its current text is saved first into the existing `ops.function_backup` table and into the rollback file.
- **Thresholds in config.** New numeric keys go in the existing `silver.sidnl_config(key, value_num, description)`
  and are read with `silver.cfg()`. Per-platform freshness thresholds go in a new table (a key/value table cannot hold them).
  Config rows are real settings, not sample data.
- **No secrets in SQL.** Webhook URLs and API keys live in Vault or edge-function secrets.
- Every new view is `security_invoker = true` (matches `silver_050`). Every new table has RLS enabled with no policies,
  readable through the service role (matches the existing `ops` tables).

---

## Gap 1: Gold failure handling (migration `dash_006_gold_failure_retry`)

**Mechanism.** Replace `run_gold_pending()` so that `sync_dims` and `refresh` run in **one** savepoint. Any error there,
including a `dash.refresh` error, goes to the existing outer failure path:
`gold_status='failed'`, `gold_error`, `gold_attempts+1`, and `gold_next_at = now() + backoff_minutes(attempt)` only when
`classify_error(sqlstate)='transient'` and `attempt < cfg('gold_max_attempts')`. Same rules as Silver.
- Add an explicit `exception when query_canceled` branch that records the timeout as a transient failure, so a timeout
  no longer loops every minute. This must be proven in Phase 3 by lowering `statement_timeout` inside a rolled-back
  transaction. If a caught timeout cannot then run the UPDATE, I will report it and drop this branch rather than claim it works.
- A rolled-back savepoint means the previous `dash.*` rows stay served (§0.2). `dash.refresh_state('last_error')` is still
  written on failure and deleted on success, which keeps the current contract.
- Superseding is unchanged: a newer successful Silver run creates a new `pending` row that wins over a failed row
  still waiting for retry. A permanently failed or exhausted run therefore recovers at the next good Silver run,
  and also through the daily forced run.

**New objects**
- `dash.refresh_table_state(table_name text pk, last_refreshed_at timestamptz, last_run_id bigint, row_count bigint,
  last_attempt_at timestamptz, last_status text, last_error text)`. `run_gold_pending` upserts one row per dash table
  (`pricing, availability, visibility, overview, supply, ads`, and the 7 `dim_*` tables). `last_refreshed_at` moves only on
  success. Failures update `last_attempt_at` and `last_status` from the outer handler.
- `dash.v_refresh_status`: one row per table with `last_refreshed_at`, `age_minutes`, `last_status`, `last_error`,
  `gold_attempts`, `gold_next_at`, and `is_stale = age_minutes > cfg('gold_stale_minutes') or last_status='failed'`.
  The app shows "Last refreshed {time}" and a "stale" badge from this view.
- Config: `gold_max_attempts = 5`, `gold_stale_minutes = 180` (proposed; Silver runs about every 2–5 minutes while data flows, so
  3 hours without a Gold refresh while Silver succeeds is abnormal). *Confirm (Q4).*
- An empty table (overview, supply, ads) refreshes successfully but has 0 rows. The view exposes `row_count` so the app can say "no
  data feed" instead of "stale".

**Rollback** (`dash_006_rollback.sql`): restore the saved `run_gold_pending` text, drop the view and the table, and delete the
two config keys. No data is lost (state only).

---

## Gap 2: Scraper stopped or stale (migration `dash_007_data_freshness`)

**Mechanism.** A read-only view over bronze. It reads `max(time)` per platform from the three sources in §0.3, which are small
(18k, 7k and 4.7k rows), so no bronze index is needed. **No bronze table is changed.**

**New objects**
- `ops.freshness_threshold(platform text, source text, max_age_hours numeric, is_expected boolean, primary key (platform, source))`.
  `platform='*'` is the default row for each source. A specific row overrides it.
- `dash.v_data_freshness(platform, source, last_row_at, age_hours, max_age_hours, status)` with
  `status ∈ {fresh, stale, no_data, not_expected}`. Platforms come from `silver.dim_platform where not is_test`.
- `dash.v_platform_freshness(platform, last_row_at, status)`: the worst status across the platform's expected sources.
  The dashboard shows a "Data stale since {last_row_at}" banner per platform when `status <> 'fresh'`.
- `silver.check_freshness_alert()`: called from `record_storage_snapshot` next to the two existing checks (same
  `exception` guard). It logs to the outbox from Gap 4 on each fresh->stale and stale->fresh change, not every minute.

**Proposed seed** (real config, not data). *Confirm (Q4).*
| platform | source | max_age_hours | is_expected |
|---|---|---|---|
| `*` | shelf_snapshots | 6 | true |
| `*` | search_snapshots | 26 | true |
| `*` | observations | 26 | true |

With these values, as of today, blinkit shelf shows `fresh`; blinkit search and observations and all zepto sources show `stale`;
instamart and jiomart show `no_data`. That is what the data actually says. If some platform/source pairs are not
supposed to be scraped, set `is_expected=false` for them (Q4).

**Rollback:** drop the two views, the function, the table, and restore `record_storage_snapshot` to its saved text.

---

## Gap 3: Dead-letter table for bad rows (migration `silver_056_dead_letter`). **Needs a decision (Q3).**

**What "bad row" means here.** Rows that fail a DQ rule are already kept in silver with `dq_status <> 'valid'` (none today),
so they are never silently dropped. The real failure mode is #7 in §0.4: **one row that breaks a constraint raises for
the whole brand or category scope**, so the scope is marked failed, its watermark stops, and nothing new for that scope loads.

**Proposed mechanism (option A, recommended).** Quarantine at the scope level by bisecting bronze id ranges. This requires
changing the loaders:
1. New table `ops.dead_letter(dl_id, source_table, bronze_id, platform, platform_product_id, scope, reason, sqlstate,
   first_seen_at, last_tried_at, retry_count, status ∈ {open, resolved, ignored}, resolved_at, resolved_by)`,
   unique on `(source_table, bronze_id)`.
2. New `silver.isolate_bad_rows(scope, lo, hi)`: when a scope load fails with a **permanent** SQLSTATE, re-run the
   chunk loader on halves of the id range, each in its own savepoint, until it finds the single bronze ids that raise
   (log2(50,000) ≈ 16 levels at most). Those ids go to `ops.dead_letter` with the error text.
3. The loaders (`refresh_category_scope`/`refresh_category_products` and the shelf part of `refresh_brand`) gain one
   predicate: `and not exists (select 1 from ops.dead_letter d where d.status='open' and d.source_table=… and d.bronze_id=…)`.
   **This is the change to existing functions that needs your approval.** The SI id / resequence logic is not touched.
4. Watermark guarantee: the scope watermark may advance past a dead-lettered id **only because** that id is recorded as `open`.
   `ops.v_dq_summary` and `ops.v_silver_health` keep their contract. A new `ops.v_dead_letter_open` view shows the count, and
   any `open` row makes the scope show `degraded` in a new `ops.v_scope_health` view. Nothing is skipped silently.
5. Retry: `silver.retry_dead_letters()` runs from `run_tick` every `cfg('dead_letter_retry_minutes')` (proposed 60). For each open row it re-runs the
   loader for exactly that id. Success sets `status='resolved'`. Failure increments `retry_count` and stores the latest error.
   After `cfg('dead_letter_max_retries')` (proposed 24) the row stays `open` but drops out of automatic retry and raises an alert.
6. Clear manually after fixing the cause: `select silver.retry_dead_letters(p_force => true)`, or
   `update ops.dead_letter set status='ignored', resolved_by='<you>'` with a reason. Rows are never deleted.

**Option B (smaller).** No loader changes. Only build `ops.dead_letter` plus scope-level quarantine: record the failing
scope, its id range and the error, and retry it on the Silver backoff. A bad row then still blocks its own scope (other scopes
are unaffected, as today). This does **not** meet "batch proceeds", so scenario 10 would be reported as only partly covered.

---

## Gap 4: Alert delivery (migration `silver_057_alert_outbox` + edge function `alert-dispatch`)

**Mechanism: outbox in SQL, delivery by a Supabase edge function.**
- Why an edge function and not pg_net from SQL: (1) no pg_net is installed today, and a sender in SQL would put the
  webhook into SQL context, while edge-function secrets keep it out of the database. (2) Email (Resend or SMTP API) needs
  HTTP headers, JSON bodies and error parsing, which are much simpler in TypeScript. (3) The function **can be tested
  locally with Deno against a local HTTP receiver** (Deno is installed), which scenarios 11 and 12 need. A pg_net
  sender cannot reach a local receiver from the cloud database.
- What triggers it: pg_cron cannot call HTTP without pg_net. **Recommendation:** enable `pg_net` and add a cron job
  `sidnl-alerts` (every minute) that only calls `net.http_post` to the function URL. The service key is stored in Vault and read
  inside the cron command, never written into the command text. Alternative without pg_net: let the external monitor from Gap 5 also
  call `alert-dispatch` every 5 minutes. That needs no extension, but delivery stops if the external monitor stops. *Decision (Q5).*

**New objects**
- `ops.alert_outbox(alert_id, dedupe_key text unique, source ∈ {cron, storage, freshness, gold, dead_letter, heartbeat},
  severity, title, body, created_at, status ∈ {pending, sending, sent, failed, dead, disabled}, attempts, next_attempt_at,
  claimed_at, sent_at, last_error, channel)`.
- Triggers `after insert` on `ops.cron_alert_log` and `ops.storage_alert_log` (the existing writers stay unchanged) insert into
  the outbox with `dedupe_key = '<table>:<alert_id>'` and `on conflict do nothing`. A re-run cannot create a duplicate.
- `ops.alert_claim(p_limit int)`: `update … set status='sending', claimed_at=now(), attempts=attempts+1 where alert_id in
  (select … where status='pending' and next_attempt_at<=now() for update skip locked) returning …`. It also reclaims rows stuck in
  `sending` for more than `cfg('alert_claim_timeout_minutes')` (5). See the delivery-guarantee note below.
- `ops.alert_mark(alert_id, ok bool, err text)`: on success `sent`; on failure `pending` with
  `next_attempt_at = now() + backoff_minutes(attempts)`, or `dead` after `cfg('alert_max_attempts')` (6).
- `ops.v_alert_outbox_health`: pending, dead and oldest-pending age.
- **Disabled by default:** config `alert_delivery_enabled = 0`. While it is 0, `alert_claim` returns nothing and new rows are kept as
  `pending`. The edge function also refuses to send if its secret `SLACK_WEBHOOK_URL` (or `RESEND_API_KEY` + `ALERT_EMAIL_TO`) is
  missing. **I will ask you for the secret and you set it yourself; I never see or write it.**
- Delivery guarantee: no duplicates under normal operation (claim plus unique `dedupe_key`). If the function crashes *after* Slack
  accepted the message but *before* `alert_mark`, the reclaim would send it again. To prefer "no duplicate" over "always
  delivered", reclaimed `sending` rows become `failed` (shown in the health view), not resent. *Confirm (Q5).*

**Rollback:** drop the triggers, functions, view and table. Remove the `sidnl-alerts` cron job and, if it was added by this work,
the pg_net extension. Delete the function with `supabase functions delete alert-dispatch`.

---

## Gap 5: Cron or `run_tick` never starts (edge function `heartbeat` + migration `silver_058_heartbeat_view`)

**Mechanism.** The database cannot alert about its own scheduler being dead, so an **external** monitor polls a URL.
- `ops.v_heartbeat`: one row per `sidnl-*` job with `active`, `last_start`, `last_status`, `expected_interval`
  (from config: `heartbeat_pipeline_max_minutes = 10`, `heartbeat_gold_max_minutes = 10`, `heartbeat_daily_max_hours = 26`),
  and `overdue bool`. It adds rows for `latest ops.pipeline_run.started_at` (allowed to be idle: overdue only if bronze
  advanced past the watermark and no run started in `heartbeat_run_max_minutes = 30`) and for the oldest pending outbox row.
  A paused job (`active=false`) is always overdue.
- Edge function `heartbeat` (GET, no body, `verify_jwt=false`, no data in the response beyond job names, ages and
  `ok/overdue`) reads `ops.v_heartbeat` with the service role. It returns **200** when nothing is overdue and **503** with the list
  otherwise. It also returns 503 if the database itself cannot be reached.
- Fix for §0.4 #5: `enqueue_daily` stays unchanged. A **new** cron command for `sidnl-pipeline-daily` adds
  `set lock_timeout='5s'` and wraps the call so a lock wait on an already-queued daily job counts as success
  (`select silver.enqueue_daily_safe('cron-daily')`, a new wrapper that catches `lock_not_available` and returns null).
  *This changes a cron command. Confirm (Q6).*

**What you must set up outside Supabase**
1. An uptime monitor (for example UptimeRobot, Better Stack or Healthchecks.io) polling
   `https://jqxnaqbvwgmfkyzfincy.supabase.co/functions/v1/heartbeat` every 5 minutes and alerting you on non-200 for 2 checks in a row.
2. The Slack webhook URL or email API key, entered by you as edge-function secrets.

**Rollback:** drop the view and the wrapper, restore the old daily cron command, and delete the function.

---

## Gap 6: Recovery runbook
A new `docs/runbook.md` (the brief's path; or a section in `docs/silver/SILVER_OPERATIONS.md`, per Q1) with "if X breaks, do Y"
written **only after** the Phase 3 tests, and only for behaviour that passed.

---

## Phase 3 test plan (summary)
- `tests/test_fallbacks.py`, skipped without `SUPABASE_DB_URL`. Each test opens a transaction and records a baseline of
  row counts (`ops.pipeline_run`, `ops.pipeline_job`, `dash.*`, `silver.fact_*`, `silver.product_xref`), `cron.job.active` and
  `md5(pg_get_functiondef)` of every function it touches. It injects the fault with `create or replace function` *inside the
  transaction* (for example a `dash.refresh` that raises `40001` or `22012`), calls the function directly, asserts, then runs
  `ROLLBACK` and re-checks the baseline in a new transaction.
- Scenarios 1–4, 6–12: in-transaction. Scenario 10 injects a fault by adding a `CHECK … NOT VALID` constraint inside the
  transaction that rejects a few **real** bronze-derived rows (no rows inserted). Scenarios 11 and 12 combine the in-transaction SQL with
  `deno test` of `alert-dispatch` against a local `http.server` receiver (200 vs 500/timeout).
- Scenarios 5 and 13 need real pg_cron behaviour (cron cannot see uncommitted changes). Without a branch, I will test their
  SQL parts in a transaction (catch-up query logic; `v_heartbeat` with a job set to `active=false` inside a transaction) and **mark the
  cron-dependent part "not tested"**.
- Scenario 2 note: running the real pipeline in a test transaction is slow (each run takes 30–40 s of real work). Tests
  call `run_pipeline` / `run_gold_pending` directly with a `statement_timeout` budget, and nothing is committed.

---

## Questions before Phase 2
- **Q1. File locations.** Should I use the brief's `supabase/migrations/` + `supabase/rollbacks/` + `docs/runbook.md`, or the repo's
  existing `sql/silver/live/`, `sql/dash/`, `sql/*/NNN_rollback.sql` + `docs/silver/SILVER_OPERATIONS.md`? I recommend the existing layout.
- **Q2. Supabase branch** for scenarios 5 and 13: create one (paid; I will show the cost first), or accept "not tested" for the cron-only parts?
- **Q3. Dead-letter:** option A (changes loaders, meets "batch proceeds") or option B (no loader change, partial)?
- **Q4. Thresholds:** `gold_stale_minutes=180`; freshness 6h shelf / 26h search and observations; which platform/source pairs are expected
  (are instamart and jiomart scraped at all? Is zepto observation scraping meant to be off?).
- **Q5. Alerts:** enable `pg_net` + `sidnl-alerts` cron, or external-poll only? Slack, email, or both? Accept "at most once" on a crash?
- **Q6.** OK to change the `sidnl-pipeline-daily` cron command to use the lock-safe wrapper?
