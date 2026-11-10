-- Rollback for silver_059_maintenance_automation. (ANALYZE only refreshed statistics; nothing to undo.)
select cron.unschedule('sidnl-maintenance');
drop function if exists silver.run_maintenance();
delete from silver.sidnl_config where key = 'cron_history_keep_days';
