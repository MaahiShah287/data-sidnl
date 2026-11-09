# Silver pipeline: operations

Run history, quality results and monitoring live in schema `ops` (not silver). SI ids are re-sorted A-Z by product name at the end of each run (`silver.resequence_sidnl()`).

## What runs
| cron job | schedule | command | purpose |
|---|---|---|---|
| sidnl-pipeline | every minute | `select silver.run_tick()` | picks a due queued/retry job, otherwise runs the regular incremental check |
| sidnl-pipeline-daily | 18:35 UTC = 00:05 IST | `select silver.enqueue_daily('cron-daily', false)` | queues one forced full run per IST date (unique); cannot be lost to the run lock |
| sidnl-gold | every minute | `select silver.run_gold_pending()` | Gold refresh in its own transaction, lock (727101) and status |

`run_tick()` also re-creates today's daily job if cron missed it (after 00:05 IST) and records a daily storage snapshot.

## Silver run (silver.run_pipeline)
1. Lock 727100 (xact advisory). If held: returns `skipped`; a queued job stays queued, `lock_waits` increases, re-check after 50 s, visible failure after 3 h.
2. discover (platforms, categories, brands) -> refresh brands (isolated per brand) -> refresh category scopes (isolated per category, own watermark `category_scope.last_loaded_id`) -> canonical map -> quality gate.
3. Status: `success`, `partial` (a step failed), `blocked` (gate blocked a scope). Gold never changes it.
4. Watermarks: a category advances only if it loaded and passed the gate; shelf sources only if every category passed; other sources only if brands/discover/canonical passed. Blocked or failed data is re-read on the next run (idempotent upserts).

## Quality gate (silver.dq_checks, results in ops.dq_result)
| severity | rule | effect |
|---|---|---|
| blocking | shelf row without product / store / brand, bronze rows missing from Silver in the window, canonical self-tests, SI id integrity | blocks the scope, watermark held |
| rejected | negative selling price | row excluded from valid output (`dq_status=invalid`); scope blocked only above `dq_reject_block_pct` (5 %) |
| warning | selling price > MRP | excluded from price/discount metrics, never blocks |
| accepted | missing store city/coords, product category, empty `name_clean` | recorded only |

## Retry (ops.pipeline_job)
Max 5 attempts including the first; waits 2, 4, 8, 16 min. Retried jobs run forced. SQLSTATE classes 22, 23, 42, 0A, 2B, 44, 0L, 28 and gate blocks are permanent: recorded, not retried. Each job stores status, attempt, failed stage, error class, last error, lock waits.

## Monitor
`select * from ops.v_silver_health;` (one row) · `ops.v_job_history` · `ops.v_dq_latest` · `ops.v_storage_monitor` · `ops.storage_snapshot` · `ops.v_storage_projection` · `ops.v_cron_health`.

## Manual operations
- Force a full reload now: `select silver.run_pipeline(true, 'manual');` (about 100 s; Gold follows by cron).
- Re-run a blocked scope after fixing its cause: `select silver.run_pipeline(true, 'manual');`
- Review queue: `select * from silver.match_review_queue where status='pending';` then `silver.approve_match(...)`.


## Storage (Supabase Pro; all history kept, no retention / archival / deletion)
Decision (company, 2026-11-08): Supabase Pro is active; no historical data is deleted, archived or partitioned away to save space.
Monitoring only: `ops.v_storage_projection` (usage, bytes per scraped row, growth per day at recent average and at peak, days to full), `silver.storage_usage()`, `silver.check_storage_alert()` (called from every tick; logs level changes to `ops.storage_alert_log`, repeats non-ok levels daily, emits a WARNING), `ops.storage_snapshot` (daily per-table sizes).
Thresholds in `silver.sidnl_config`: `storage_plan_gb` (8, confirm in dashboard > Settings > Compute and Disk), `storage_warn_pct` (70), `storage_crit_pct` (85). Usage = database size + WAL directory.
Cron failures that PL/pgSQL cannot catch (statement timeout) are visible in `ops.v_cron_health`.
`storage_plan_gb` is an UNVERIFIED assumption until the Compute Disk size is read from Settings → Compute and Disk (the 100 GB billing Storage Size quota is a different thing). Change it only with evidence: `update silver.sidnl_config set value_num=<GB> where key='storage_plan_gb';`

## Gold refresh

Gold refresh is incremental for visibility and runs only after a clean Silver
run. A partial Silver run leaves the previous clean Gold data in place.
`gold.sync_dims()` runs once per `gold.refresh_all()` transaction via the
transaction-local `gold.dims_synced` setting. Visibility refresh records
changed shelf dates in `gold.refresh_state`, rebuilding only changed dates
unless its configuration inputs change. The full visibility refresh seeds
that state. Gold uses `DELETE`, not `TRUNCATE`, so refresh does not block
readers with a truncate lock.

Metric-named Gold objects are views over existing Gold data; they add no
storage or metric refresh work. See
[GOLD_METRIC_VIEWS.md](../gold/GOLD_METRIC_VIEWS.md) for the documented view
names and the limits caused by missing source data.


## Cron failure alert (044)
- `ops.v_cron_health`: per `sidnl-*` job: runs/failures 24 h, last success/failure, `consecutive_failures` = `failed` runs since the last `succeeded` run. Running/starting/sending/connecting executions are never counted.
- `silver.check_cron_alert()` (called each tick from `record_storage_snapshot`, inside an exception block so it can never break a run): at `consecutive_failures >= cron_alert_consecutive_failures` (3, in `silver.sidnl_config`) writes one `alert` row to `ops.cron_alert_log` and a WARNING; repeats at most daily; writes `recovered` when the streak ends.
- Check: `select * from ops.v_cron_health; select * from ops.cron_alert_log order by alert_id desc;`
- Limit: if cron or `run_tick` never starts, nothing inside the database can alert; watch `v_cron_health.last_success_at` externally if needed.
