-- Rollback for silver_062_bronze_freshness. (Alert rows it wrote to ops.cron_alert_log stay as history.)
select cron.unschedule('sidnl-freshness');
drop function if exists silver.refresh_freshness();
drop view if exists dash.v_platform_freshness;
drop view if exists dash.v_data_freshness;
drop table if exists ops.freshness_event;
drop table if exists ops.freshness_override;
drop table if exists ops.freshness_state;
drop table if exists ops.freshness_cursor;
delete from silver.sidnl_config where key = 'freshness_lookback_rows';
