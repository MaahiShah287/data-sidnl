-- Rollback for silver_061_reconciliation.
select cron.unschedule('sidnl-reconcile');
drop function if exists silver.reconcile();
drop view if exists ops.v_reconciliation_latest;
drop table if exists ops.reconciliation_log;
delete from silver.sidnl_config where key = 'reconcile_window_days';
