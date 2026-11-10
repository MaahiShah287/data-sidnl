# SIDNL data platform

Quick-commerce analytics (Blinkit, Zepto, Instamart, JioMart; Flipkart Minutes, BigBasket, Amazon Now when their
scrapers land) on Supabase project `jqxnaqbvwgmfkyzfincy`. Everything runs **inside the database** on pg_cron; nothing
needs to be started or run by hand. How it works in detail: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

```
bronze  public.*  (raw scraper tables, read-only for us)
   │  silver.run_tick()  every minute
   ▼
silver  cleaned facts + one SI id per real product          (silver.*)
   │  silver.run_gold_pending()  every minute, after a successful silver run
   ▼
dash    front-end tables, rebuilt from silver              (dash.*)  ──►  portal/ (Next.js)
ops     run history, quality results, alerts, checks       (ops.*)
```

## Files
| File | What |
|---|---|
| `sql/01_tables.sql` | schemas, types, sequences, tables, constraints, indexes, RLS, comments |
| `sql/02_functions.sql` | every function (exact live text) |
| `sql/03_views_jobs_config.sql` | views, grants, configuration rows, the pg_cron jobs |
| `sql/rollbacks.sql` | the rollback for each migration since `silver_041` (undo newest first) |
| `sql/manifest.csv` | every applied migration: version, name, md5 of the applied SQL |
| `sidnl.py` | command line (below) |
| `tests/test_live_db.py` | tests against the live database (skipped without `SUPABASE_DB_URL`) |
| `edge-functions/heartbeat/` | uptime check for Gap 5 (not deployed, see owner steps below) |
| `portal/` | Next.js dashboard reading `dash.*` |

`sql/01..03` are **generated** from the live database (`python sidnl.py export-schema`) and checked by
`python sidnl.py verify`. They are documentation and a recovery baseline, never applied to production. The exact SQL of
every migration ever applied is kept by Supabase in `supabase_migrations.schema_migrations`.

## Use
```bash
pip install -r requirements.txt
export SUPABASE_DB_URL='postgresql://...'      # Supabase > Connect > Session pooler. Never commit it.
python sidnl.py report                          # health, gold refresh, freshness, reconciliation, dead letters, cron
python sidnl.py test                            # in-database self-tests (parser, matcher, quality checks)
python sidnl.py run [--force]                   # run bronze -> silver now (cron does this every minute)
python sidnl.py verify                          # repo sql/ == live database?
python -m unittest discover -s tests -v
```

## The automation (pg_cron)
| Job | When | What it does |
|---|---|---|
| `sidnl-pipeline` | every minute | `silver.run_tick()`: runs a queued/retry job or checks bronze for new rows; loads brands and category shelves, maps products to SI ids, re-sorts SI ids A-Z, quality gate, watermarks. Retries 2/4/8/16 min; permanent errors are not retried |
| `sidnl-pipeline-daily` | 18:35 UTC (00:05 IST) | queues one forced full run per day |
| `sidnl-gold` | every minute | `silver.run_gold_pending()`: rebuilds `dash.*` after a successful silver run; on failure keeps the last good data and retries with backoff |
| `sidnl-auto-match` | every 10 min | merges a product into an SI id on another platform only when brand, name and parsed size are identical |
| `sidnl-store-city` | every 10 min | gives a store without a city the single city its bronze snapshots record |
| `sidnl-freshness` | every 5 min | per platform × source, when bronze last received data; flags stale scrapers |
| `sidnl-dead-letter` | every 15 min | retries bronze rows that failed to load |
| `sidnl-maintenance` | 19:05 UTC | purges cron history > 14 days, analyzes tables without statistics |
| `sidnl-reconcile` | 19:20 UTC | proves every silver row equals its bronze row and every dash number equals silver |
| `sidnl-reconcile-coverage` | 19:40 UTC | proves no bronze shelf row was skipped (in silver or dead-lettered) |
| `sidnl-alerts` | every minute | `silver.deliver_alerts()`: sends queued alerts to Slack (off until you add the webhook and switch it on) |

## Where to look
```sql
select * from ops.v_silver_health;            -- one row: last run, errors, retries, rows behind
select * from dash.v_refresh_status;          -- per dash table: last refreshed, stale, failing
select * from dash.v_platform_freshness;      -- per platform: fresh / stale / no_data (from bronze)
select * from ops.v_reconciliation_latest;    -- bronze -> silver -> dash checks, must all be ok
select * from ops.v_dead_letter_summary;      -- bronze rows that could not be loaded
select * from ops.v_cron_health;              -- every sidnl-* job: runs, failures, streak
select * from ops.cron_alert_log order by alert_id desc limit 20;   -- every alert raised
select * from dash.v_brand_scorecard_latest where brand_key = 'amul';  -- a brand's market position
```

## Runbook: if X breaks, do Y
| Symptom | Where you see it | What happens on its own | What you do |
|---|---|---|---|
| A silver step fails (transient) | `ops.v_silver_health.jobs_waiting_retry` | retried at 2/4/8/16 min | nothing, unless 5 attempts fail |
| A silver step fails (permanent: bad data, bug) | `ops.pipeline_job.status='failed'`, `error_class='permanent'` | not retried; other brands/scopes keep loading | fix the cause, then `select silver.run_pipeline(true, 'manual');` |
| Quality gate blocks a scope | `ops.v_dq_latest`, `category_scope.last_status='blocked'` | only that scope stops; its watermark holds; nothing lost | fix the bronze/data cause; next run reloads it |
| A few bronze shelf rows break the load | `ops.v_dead_letter_summary` | only those rows are parked; the rest loads; retried every 15 min | fix the cause, or close a row: `select silver.ignore_dead_letter(<dl_id>, '<you>', '<reason>');` |
| Gold (dash) refresh fails | `dash.v_refresh_status.refresh_failing` | old dash data stays; retried with backoff (permanent errors stop: `needs_attention`) | fix, then `update ops.pipeline_run set gold_status='pending' where run_id=(select max(run_id) from ops.pipeline_run where status='success');` |
| A scraper stops | `dash.v_platform_freshness.status='stale'`, alert `freshness:<platform>/<source>` | banner data available to the app; alert row written | fix the scraper; the flag clears by itself |
| Numbers stop matching bronze | `ops.v_reconciliation_latest` mismatch, alert `sidnl-reconcile:data` | nothing is changed automatically | investigate before trusting the dashboard |
| A cron job keeps failing | `ops.v_cron_health.consecutive_failures >= 3`, `ops.cron_alert_log` | alert row; `recovered` row when it heals | read `cron.job_run_details.return_message` |
| Cron itself / the database stops | nothing inside the database can tell | — | External uptime monitor polling the `heartbeat` edge function every 5 min (see owner steps) |
| Alerts reach nobody | `ops.alert_outbox`, `ops.v_alert_outbox_health` | rows retry with backoff (2/4/8/16 min), `dead` after 6 | check `slack_webhook_url` in Vault and `alert_delivery_enabled = 1`; see owner steps |

## Owner steps to activate alerts and heartbeat (Gaps 4 and 5)
The database side is **built and applied** (`silver_064_heartbeat`, `silver_065_alert_outbox`): `ops.v_heartbeat`,
`ops.heartbeat()`, `silver.enqueue_daily_safe()`, the alert outbox with triggers, `ops.alert_claim()` / `ops.alert_mark()`.
Delivery is **off** (`alert_delivery_enabled = 0`); alerts are collected in `ops.alert_outbox` once delivery is on.
What is left needs your accounts and decisions (nothing below has been done, and the heartbeat edge function has **not been
deployed or tested** - only the database side was tested; Gap 4 needs no edge function):

0. **The heartbeat function** calls `ops.heartbeat()` through Supabase's REST API, which exposes only `public` by default: add
   `ops` under Dashboard > Project Settings > API > Exposed schemas first (`ops` tables stay unreadable: RLS is on and only
   `service_role` can call the definer function).

### Gap 5 - heartbeat (uptime monitoring)
1. `supabase functions deploy heartbeat --no-verify-jwt`
2. Point an external uptime monitor (UptimeRobot, BetterStack, ...) at
   `https://jqxnaqbvwgmfkyzfincy.supabase.co/functions/v1/heartbeat` every **5 minutes**: 200 = all jobs on time,
   503 = a job is overdue, paused, last run failed, or the database is unreachable.
3. Optional, recommended (changes a cron command, so it needs your OK): make the daily job lock-safe. It timed out on
   2026-11-09 because `run_tick` had already queued the same daily job.
   ```sql
   select cron.unschedule('sidnl-pipeline-daily');
   select cron.schedule('sidnl-pipeline-daily', '35 18 * * *', $cmd$select silver.enqueue_daily_safe('cron-daily')$cmd$);
   ```
   then `python sidnl.py export-schema`, `python sidnl.py verify`, commit.

### Gap 4 - alert delivery (Slack): built and applied (`silver_066_alert_delivery`), switched OFF
Alerts are sent **from the database** (pg_net, installed) by the `sidnl-alerts` cron job. No edge function, no exposed
schema, no service-role key. Two things are left, and only you can do them (the webhook is a secret: never paste it in
chat or a file):
1. In the Supabase SQL editor, store your Slack incoming-webhook URL in Vault:
   `select vault.create_secret('https://hooks.slack.com/services/...', 'slack_webhook_url');`
2. Switch delivery on and send a test:
   ```sql
   update silver.sidnl_config set value_num = 1 where key = 'alert_delivery_enabled';
   select silver.send_test_alert();     -- a "Test alert" should appear in Slack within a minute
   ```
Check: `select * from ops.v_alert_outbox_health;` and `select status, attempts, last_error from ops.alert_outbox order by alert_id desc limit 10;`
To stop: `update silver.sidnl_config set value_num = 0 where key = 'alert_delivery_enabled';`

## Changing the database (the only way)
1. Write a migration `silver_NNN_slug` / `dash_NNN_slug`.
2. Dry run it inside a transaction that is rolled back (end the script with a `raise exception` that prints the results).
3. Apply with Supabase `apply_migration`; check that `md5(array_to_string(statements, E'\n'))` equals the md5 of your file.
4. Append its rollback to `sql/rollbacks.sql`.
5. `python sidnl.py export-schema`, then `python sidnl.py verify`, then commit and push to `main`.

Rules: bronze is never written; no invented or sample data; SI-id logic (`silver.resequence_sidnl`) is never changed;
secrets only in Supabase Vault / edge-function secrets.
