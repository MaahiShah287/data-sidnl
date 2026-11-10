# Unapplied drafts from commit b314c08 (2026-11-10, upengupta20-06)

These files were committed under `sql/silver/live/` (which in this repo means "exact SQL that was applied"), but **none
of them were ever applied** to project `jqxnaqbvwgmfkyzfincy` (checked against `supabase_migrations.schema_migrations`).
They were moved here so `live/` only holds applied migrations. **Do not apply them as they are.**

| File | Status | Why not to apply |
|---|---|---|
| `20261110121500_silver_063_dead_letter.sql` + `063_rollback.sql` | superseded | Gap 3 is live as `silver_063_dead_letter` version `20261110112254` (`sql/silver/live/20261110112254_silver_063_dead_letter.sql`). This draft also creates `ops.dead_letter` and `silver.retry_dead_letters()` and would collide with the live objects. |
| `20261110124500_silver_064_heartbeat.sql` + `064_rollback.sql` | draft for Gap 5 | Not applied. Re-check against the live schema before use; the config keys / view names may overlap with later work. |
| `20261110130000_silver_065_alert_outbox.sql` + `065_rollback.sql` | draft for Gap 4, has a bug | Its trigger `ops.alert_log_to_outbox()` on `ops.cron_alert_log` reads `new.severity`, `new.title`, `new.details`, `new.message`, but that table has `jobname, level, consecutive_failures, last_failure_message`. Applied as-is, **every insert into `ops.cron_alert_log` would fail** (cron, freshness, reconcile and dead-letter alerts). |

The edge functions from the same commit (`edge-functions/alert-dispatch`, `edge-functions/heartbeat`) were left where
they are; they are not deployed.
