-- =============================================================================
-- File:    064_rollback.sql
-- Reverts: 20261110124500_silver_064_heartbeat.sql
-- =============================================================================

drop view if exists ops.v_heartbeat;
drop function if exists silver.enqueue_daily_safe(p_reason text);

delete from silver.sidnl_config
 where key in ('heartbeat_pipeline_max_minutes','heartbeat_gold_max_minutes',
               'heartbeat_daily_max_hours','heartbeat_run_max_minutes');

-- restore the previous sidnl-pipeline-daily cron command from
-- ops.function_backup / the migration ledger if step 4 was applied:
--   select cron.unschedule('sidnl-pipeline-daily');
--   select cron.schedule('sidnl-pipeline-daily', '35 18 * * *',
--     'set statement_timeout=''600s''; select silver.enqueue_daily(''cron-daily'', false);');
