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
| `sql/migrations/` | exact SQL of the migrations applied since 2026-11-11 (`silver_069`–`073`, `dash_011`); md5 in `manifest.csv`, checked by the tests. Status report: [docs/PIPELINE_STATUS_2026-11-11.md](docs/PIPELINE_STATUS_2026-11-11.md) |
| `sql/pending/` | migrations written but not yet applied (apply order in `ORDER`); empty today |
| `sidnl.py` | command line (below) |
| `tests/test_live_db.py` | tests against the live database (skipped without `SUPABASE_DB_URL`) |
| `tests/test_offline.py` | tests that need no database: bronze→silver column contract, migrations (rollback, md5, preflight, parse), CLI retry |
| `portal/` | Next.js dashboard reading `dash.*` |

`sql/01..03` are **generated** from the live database (`python sidnl.py export-schema`) and checked by
`python sidnl.py verify`. They are documentation and a recovery baseline, never applied to production. The exact SQL of
every migration ever applied is kept by Supabase in `supabase_migrations.schema_migrations`.

## Use
```bash
pip install -r requirements.txt
export SUPABASE_DB_URL='postgresql://...'      # Supabase > Connect > Session pooler. Never commit it.
python sidnl.py report                          # health, gold refresh, freshness, reconciliation, dead letters, cron
python sidnl.py test                            # in-database self-test suite (silver.selftest once silver_071 is applied)
python sidnl.py dry-run                         # apply sql/pending/* in one transaction, print effect + timings, roll back
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
| `sidnl-context` | every 10 min | `silver.refresh_scrape_context()` then `dash.refresh_context()`: run logs, shelf reads, serviceability, listings into silver; `dash.coverage` + `dash.collection_health`. Each part isolated; result in `ops.etl_run` (`brand_key = '_context'`) |
| `sidnl-fp-ads` | every 10 min (+ on every upload, trigger) | `silver.load_fp_ads()` then `dash.refresh_ads()`: first-party ads exports -> silver -> `dash.ads`, `ads_campaign_period`, `ads_keyword_sov`, columns from the formula sheet |
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
select * from silver.selftest() where not ok;  -- the self-test suite (35 tests); no rows = all pass
select * from dash.collection_health order by obs_date desc;  -- scrape runs ok / partial / failed per day
select * from silver.check_fp_ads() where not ok;   -- first-party ads feed: bronze -> silver -> dash proofs; no rows = all pass
select * from dash.ads where report_level = 'campaign' order by obs_date;  -- ads per campaign-day (formula sheet: silver.ref_metric_support)
select * from dash.coverage order by obs_date desc;  -- serviceable points per platform x city
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
| Cron itself / the database stops | an external uptime monitor polling `sidnl_heartbeat` gets 503 or no answer | nothing inside the database can notice this | see owner steps (Gap 5); then check Supabase status and `cron.job_run_details` |
| Alerts reach nobody | `ops.alert_outbox`, `ops.v_alert_outbox_health` | rows retry with backoff (2/4/8/16 min), `dead` after 6 | check `slack_webhook_url` in Vault and `alert_delivery_enabled = 1`; see owner steps |

## Owner steps for Gaps 4 and 5 (both built and applied; both need your secrets, so they are off until you do this)
Run these in the Supabase SQL editor. Never paste a secret into chat or a file.

### Gap 4 - alert delivery to Slack (switched off)
Alerts are sent from the database (pg_net) by the `sidnl-alerts` cron job; the webhook lives only in Vault.
1. `select vault.create_secret('https://hooks.slack.com/services/...', 'slack_webhook_url');`
2. `update silver.sidnl_config set value_num = 1 where key = 'alert_delivery_enabled';`
3. `select silver.send_test_alert();`  -> a "Test alert" should appear in Slack within a minute.
Check: `select * from ops.v_alert_outbox_health;`. Stop: set `alert_delivery_enabled` back to 0.
Retries: 2/4/8/16 min, `dead` after 6 attempts; a send with no answer is marked failed, never resent.

### Gap 5 - heartbeat for an external uptime monitor (the endpoint is live, locked until you create the token)
`public.sidnl_heartbeat` answers **200** when every `sidnl-*` cron job is active, started on time and its last run did not
fail (and no alert has waited over 30 min while delivery is on), **503** otherwise, **401** without the token. It is the only
object the project keeps in schema `public` (the REST API serves `public`). Its answer lists only job names, times and flags.
1. Create the token (it stays secret, only you can read it):
   `select vault.create_secret(encode(gen_random_bytes(24), 'hex'), 'heartbeat_token');`
   `select decrypted_secret from vault.decrypted_secrets where name = 'heartbeat_token';`  -> copy it.
2. In an uptime monitor (UptimeRobot, BetterStack, Healthchecks.io...) add an HTTP monitor, every **5 minutes**, alert when
   the status is not 200 for 2 checks in a row:
   `https://jqxnaqbvwgmfkyzfincy.supabase.co/rest/v1/rpc/sidnl_heartbeat?apikey=<publishable key>&p_token=<token>`
   (publishable key: Dashboard > Project Settings > API Keys; it is public by design. The token can also be sent as header
   `x-heartbeat-token`.)
3. Tested over HTTP without a token: 401 from the function, and a request without a key is rejected by the gateway.
   Not tested: the 200 and 503 answers over HTTP (they need your token); the logic for both was tested in the database.
Today it would answer 503 until the 18:35 UTC daily run succeeds, because the daily job failed on 2026-11-09.
The daily job now uses `silver.enqueue_daily_safe`, which cannot time out on the day's job row any more (`silver_068`).


## Changing the database (the only way)
1. Write a migration `silver_NNN_slug` / `dash_NNN_slug`.
2. Dry run it inside a transaction that is rolled back: put it in `sql/pending/` + `ORDER` and run `python sidnl.py dry-run`
   (or end the script with a `raise exception` that prints the results).
3. Apply with Supabase `apply_migration`; check that `md5(array_to_string(statements, E'\n'))` equals the md5 of your file.
4. Append its rollback to `sql/rollbacks.sql`.
5. `python sidnl.py export-schema`, then `python sidnl.py verify`, then commit and push to `main`.

Rules: bronze is never written; no invented or sample data; SI-id logic (`silver.resequence_sidnl`) is never changed;
secrets only in Supabase Vault.
