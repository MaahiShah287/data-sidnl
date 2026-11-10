-- silver_059_maintenance_automation
-- 1. Planner statistics: 27 silver/dash tables had never been analyzed (statistics were lost in the 2026-11-09 server
--    restart); the planner estimated silver.fact_product_reading (56,249 rows) as empty. ANALYZE them now, and let the
--    new daily job re-analyze any silver/dash table whose statistics are missing.
-- 2. cron.job_run_details is never purged by pg_cron (8,162 rows in 3 days with 3 jobs). The daily job keeps
--    sidnl_config.cron_history_keep_days (14) days; ops.v_cron_health only reads the last 7 days.
-- New cron job: sidnl-maintenance, daily 19:05 UTC (00:35 IST, after the daily forced run at 18:35 UTC).
-- No bronze table is read or written.

analyze silver.fact_product_reading;
analyze silver.fact_store_scan;
analyze silver.fact_shelf_position;
analyze silver.dim_product;
analyze silver.dim_brand;
analyze silver.dim_store;
analyze silver.dim_city;
analyze silver.dim_category;
analyze silver.dim_platform;
analyze silver.brand_scope;
analyze silver.brand_string_registry;
analyze silver.canonical_product;
analyze silver.product_xref;
analyze dash.availability;
analyze dash.pricing;
analyze dash.visibility;
analyze dash.dim_product;
analyze dash.dim_sidnl;
analyze dash.dim_brand;
analyze dash.dim_store;
analyze dash.dim_city;
analyze dash.dim_category;
analyze dash.dim_platform;

insert into silver.sidnl_config (key, value_num, description) values
  ('cron_history_keep_days', 14, 'sidnl-maintenance deletes cron.job_run_details rows older than this many days (ops.v_cron_health reads 7 days)')
on conflict (key) do nothing;

create or replace function silver.run_maintenance()
 returns jsonb
 language plpgsql
 set search_path to 'silver', 'ops', 'public', 'pg_temp'
as $function$
declare
    v_keep int := greatest(coalesce(silver.cfg('cron_history_keep_days'), 14)::int, 8);
    v_purged bigint; r record; v_analyzed text[] := '{}';
begin
    delete from cron.job_run_details where coalesce(end_time, start_time) < now() - make_interval(days => v_keep);
    get diagnostics v_purged = row_count;

    for r in select s.schemaname, s.relname from pg_stat_user_tables s
              where s.schemaname in ('silver', 'dash')
                and s.last_analyze is null and s.last_autoanalyze is null
                and pg_relation_size(s.relid) > 0
    loop
        execute format('analyze %I.%I', r.schemaname, r.relname);
        v_analyzed := v_analyzed || (r.schemaname || '.' || r.relname);
    end loop;

    return jsonb_build_object('cron_history_purged', v_purged, 'keep_days', v_keep, 'analyzed', to_jsonb(v_analyzed));
end $function$;

comment on function silver.run_maintenance() is
  'sidnl-maintenance (daily): purge old cron.job_run_details, analyze silver/dash tables that have no planner statistics.';

select cron.schedule('sidnl-maintenance', '5 19 * * *',
                     $cmd$set statement_timeout = '300s'; select silver.run_maintenance()$cmd$);
