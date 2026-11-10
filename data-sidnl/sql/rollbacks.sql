-- data-sidnl: every rollback, one section per migration, newest last. Run ONE section (as a Supabase migration, after
-- a rolled-back dry run) only to undo that migration.
-- ORDER MATTERS: a section is only valid once every NEWER migration has been rolled back first (undo newest-first).
-- Migrations older than silver_041 have no rollback (they built the base schema); restore those from sql/01..03.
-- Sections 041-050 were written before silver_047 moved the run logs to schema ops and silver_054 dropped silver.demo;
-- their object names were updated on 2026-11-10 to the objects that exist today (marked "updated 2026-11-10").
-- New migrations: append a section here in the same format.

-- ==================================================================== 20261107195949 silver_041_brand_loader_noop_guard
-- (object names updated 2026-11-10: run logs live in schema ops since silver_047)
-- Restores silver.refresh_brand to its pre-041 definition (latest backup tagged pre_041).
do $r$ declare d text; begin
  select definition into d from ops.function_backup where fn='silver.refresh_brand(text,boolean)' and tag='pre_041' order by saved_at desc limit 1;
  if d is null then raise exception 'no pre_041 backup'; end if;
  execute d;
end $r$;

-- ==================================================================== 20261107200119 silver_042_storage_alerts
-- (object names updated 2026-11-10: run logs live in schema ops since silver_047)
-- restore 039 version of record_storage_snapshot (no alert call), then drop 042 objects (all additive, no data loss)
create or replace function silver.record_storage_snapshot() returns integer language plpgsql set search_path to 'silver','ops','public','pg_temp' as $f$
declare v_d date := (now() at time zone 'Asia/Kolkata')::date; v_n int;
begin
    if exists (select 1 from ops.storage_snapshot where snapshot_date = v_d) then return 0; end if;
    insert into ops.storage_snapshot (snapshot_date, relation, total_bytes, table_bytes, index_bytes, live_rows, dead_rows, db_bytes)
    select v_d, n.nspname || '.' || c.relname, pg_total_relation_size(c.oid), pg_relation_size(c.oid), pg_indexes_size(c.oid),
           s.n_live_tup, s.n_dead_tup, pg_database_size(current_database())
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
      left join pg_stat_all_tables s on s.relid = c.oid
     where c.relkind = 'r' and n.nspname in ('silver', 'public') and pg_total_relation_size(c.oid) > 1024 * 1024
    on conflict do nothing;
    get diagnostics v_n = row_count; return v_n;
end $f$;
drop view if exists ops.v_storage_projection;
drop function if exists silver.check_storage_alert();
drop function if exists silver.storage_usage();
drop table if exists ops.storage_alert_log;
delete from silver.sidnl_config where key in ('storage_plan_gb','storage_warn_pct','storage_crit_pct');

-- ==================================================================== 20261107201340 silver_043_cron_health_view
-- (object names updated 2026-11-10: run logs live in schema ops since silver_047)
drop view if exists ops.v_cron_health;

-- ==================================================================== 20261107202823 silver_044_cron_failure_alert
-- (object names updated 2026-11-10: run logs live in schema ops since silver_047)
-- restore 042 record_storage_snapshot, 043 view definition; drop additive 044 objects
create or replace function silver.record_storage_snapshot() returns integer
language plpgsql set search_path to 'silver','ops','public','pg_temp' as $f$
declare v_d date := (now() at time zone 'Asia/Kolkata')::date; v_n int := 0;
begin
  begin perform silver.check_storage_alert(); exception when others then raise warning 'check_storage_alert failed: %', sqlerrm; end;
  if exists (select 1 from ops.storage_snapshot where snapshot_date = v_d) then return 0; end if;
  insert into ops.storage_snapshot (snapshot_date, relation, total_bytes, table_bytes, index_bytes, live_rows, dead_rows, db_bytes)
  select v_d, n.nspname || '.' || c.relname, pg_total_relation_size(c.oid), pg_relation_size(c.oid), pg_indexes_size(c.oid),
         s.n_live_tup, s.n_dead_tup, pg_database_size(current_database())
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    left join pg_stat_all_tables s on s.relid = c.oid
   where c.relkind = 'r' and n.nspname in ('silver','public') and pg_total_relation_size(c.oid) > 1024*1024
  on conflict do nothing;
  get diagnostics v_n = row_count; return v_n;
end $f$;
drop function if exists silver.check_cron_alert();
drop table if exists ops.cron_alert_log;
delete from silver.sidnl_config where key = 'cron_alert_consecutive_failures';
create or replace view ops.v_cron_health with (security_invoker = true) as
select j.jobname, j.schedule, j.active,
       count(d.runid) filter (where d.start_time > now() - interval '24 hours') as runs_24h,
       count(d.runid) filter (where d.start_time > now() - interval '24 hours' and d.status = 'failed') as failures_24h,
       max(d.start_time) filter (where d.status = 'succeeded') as last_success_at,
       max(d.start_time) filter (where d.status = 'failed') as last_failure_at,
       (select x.return_message from cron.job_run_details x where x.jobid = j.jobid and x.status = 'failed' order by x.start_time desc limit 1) as last_failure_message,
       (select count(*) from cron.job_run_details x where x.jobid = j.jobid
           and x.start_time > coalesce((select max(y.start_time) from cron.job_run_details y where y.jobid = j.jobid and y.status = 'succeeded'), '-infinity')) as consecutive_failures
from cron.job j left join cron.job_run_details d on d.jobid = j.jobid and d.start_time > now() - interval '7 days'
where j.jobname like 'sidnl-%' group by j.jobid, j.jobname, j.schedule, j.active;

-- ==================================================================== 20261109065005 silver_050_views_security_invoker
-- (updated 2026-11-10: 'if exists' because silver_054 dropped silver.demo)
-- rollback 050: return the 10 views to owner-rights execution (the pre-050 state)
alter view if exists silver.demo               reset (security_invoker);
alter view if exists silver.jiomart            reset (security_invoker);
alter view if exists silver.instamart          reset (security_invoker);
alter view if exists silver.zepto              reset (security_invoker);
alter view if exists silver.blinkit            reset (security_invoker);
alter view if exists silver.v_wide             reset (security_invoker);
alter view if exists silver.v_sku_listing      reset (security_invoker);
alter view if exists silver.v_data_freshness   reset (security_invoker);
alter view if exists silver.v_reading_current  reset (security_invoker);
alter view if exists silver.v_reading          reset (security_invoker);

-- ==================================================================== 20261109101147 dash_001_tables + dash_002_refresh
-- rollback 001 + 002: remove the dash schema (6 tables + refresh function) and the one config row 001 added.
-- Roll back 003 first if it was applied: run_gold_pending calls dash.refresh().
-- (updated 2026-11-10) guard: dash now also holds objects from dash_005..dash_009 and silver_062; refuse to drop the
-- schema while any of them exists, so this can never wipe them by running out of order.
do $guard$ begin
  if to_regclass('dash.dim_sidnl') is not null or to_regclass('dash.refresh_table_state') is not null
     or to_regclass('dash.v_brand_scorecard') is not null or to_regclass('dash.v_data_freshness') is not null then
    raise exception 'roll back dash_005..dash_009 and silver_062 first; dash still holds their objects';
  end if;
end $guard$;
drop schema if exists dash cascade;
delete from gold.cfg_threshold where key = 'low_stock_fe_units';   -- gold existed when 001 was applied (pre dash_004)

-- ==================================================================== 20261109101525 dash_003_schedule
-- rollback 003: restore silver.run_gold_pending exactly as live on 2026-11-09 (without the dash block)
create or replace function silver.run_gold_pending()
 returns jsonb
 language plpgsql
 set search_path to 'silver', 'ops', 'public', 'gold', 'pg_temp'
 set statement_timeout to '600s'
as $function$
declare v record; v_t timestamptz; v_att int; v_metrics text := 'success';
begin
    if not pg_try_advisory_xact_lock(727101) then
        return jsonb_build_object('status', 'skipped', 'reason', 'gold refresh in progress');
    end if;
    select run_id, gold_status, gold_attempts into v from ops.pipeline_run
     where status = 'success' and (gold_status = 'pending' or (gold_status = 'failed' and gold_next_at <= now()))
     order by run_id desc limit 1;
    if not found then return jsonb_build_object('status', 'idle'); end if;
    update ops.pipeline_run set gold_status = 'superseded'
     where status = 'success' and gold_status = 'pending' and run_id < v.run_id;
    v_t := clock_timestamp();
    begin
        perform gold.refresh_all();
        begin
            perform gold_stage.refresh_metrics();
            delete from gold_stage.refresh_state where key = 'last_error';
        exception when others then
            v_metrics := 'failed';
            insert into gold_stage.refresh_state (key, value) values ('last_error', left(sqlerrm, 1000))
            on conflict (key) do update set value = excluded.value, updated_at = now();
        end;
        update ops.pipeline_run set gold_status = 'success', gold_error = null, gold_next_at = null,
               gold_seconds = round(extract(epoch from clock_timestamp() - v_t)::numeric, 2) where run_id = v.run_id;
        return jsonb_build_object('status', 'success', 'run_id', v.run_id, 'metrics', v_metrics);
    exception when others then
        v_att := v.gold_attempts + 1;
        update ops.pipeline_run
           set gold_status = 'failed', gold_error = left(sqlerrm, 1000), gold_attempts = v_att,
               gold_seconds = round(extract(epoch from clock_timestamp() - v_t)::numeric, 2),
               gold_next_at = case when v_att < 5 and silver.classify_error(sqlstate) = 'transient'
                                   then now() + make_interval(mins => silver.backoff_minutes(v_att)) end
         where run_id = v.run_id;
        return jsonb_build_object('status', 'failed', 'run_id', v.run_id, 'error', sqlerrm, 'attempt', v_att);
    end;
end $function$;

-- ==================================================================== 20261109103833 dash_004_retire_gold_marts + dash_004b_drop_dead_gold_functions
-- # Rolling back 004 (gold cleanup)
--
-- 004 drops derived data only. Everything comes from silver, so a rollback rebuilds it rather than restoring it from a backup.
--
-- 1. **Restore the functions** (updated 2026-11-10: 004 never saved them; there is no `pre_dash_004` tag in
--    ops.function_backup). Their exact text is in the applied gold migrations, in version order:
--    ```sql
--    select version, name, statements from supabase_migrations.schema_migrations
--     where name like 'gold_%' or name like 'dash_00%' order by version;
--    ```
--    Re-run the gold_* statements up to dash_004 (schema and tables before functions), and run_gold_pending as of dash_003.
-- 2. **Recreate the tables:**
--    - The gold summary tables: the exact applied SQL of the `gold_*` migrations, kept by Supabase:
--      `select name, statements from supabase_migrations.schema_migrations where name like 'gold_%' order by version;`
--      (the old repo copies under sql/gold/ were removed in the 2026-11-10 consolidation; git history still has them).
--    - The `metric_*` tables and the `gold_stage` schema: migration `gold_102_lean_metric_tables` (same query).
--    - The gold views are created by the same gold_* migrations.
-- 3. **Re-fill:** `select gold.refresh_all(); select gold_stage.refresh_metrics();`
--
-- `dash.*`, the `dim_*` tables, `cfg_*` and `v_valid_reading` are untouched by 004 and need no rollback.

-- ==================================================================== 20261110094854 dash_006_gold_failure_retry
-- Rollback for dash_006_gold_failure_retry.
-- Restores silver.run_gold_pending() to its pre-006 text (also stored in ops.function_backup, tag pre_dash_006),
-- drops the new view/table and the two config rows. No dash.* or silver data is touched.
-- Apply as a Supabase migration named dash_006r_rollback_gold_failure_retry if ever needed.

drop view if exists dash.v_refresh_status;

CREATE OR REPLACE FUNCTION silver.run_gold_pending()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
 SET statement_timeout TO '600s'
AS $function$
declare v record; v_t timestamptz; v_att int; v_dash text := 'success';
begin
    if not pg_try_advisory_xact_lock(727101) then
        return jsonb_build_object('status', 'skipped', 'reason', 'dash refresh in progress');
    end if;
    select run_id, gold_status, gold_attempts into v from ops.pipeline_run
     where status = 'success' and (gold_status = 'pending' or (gold_status = 'failed' and gold_next_at <= now()))
     order by run_id desc limit 1;
    if not found then return jsonb_build_object('status', 'idle'); end if;
    update ops.pipeline_run set gold_status = 'superseded'
     where status = 'success' and gold_status = 'pending' and run_id < v.run_id;
    v_t := clock_timestamp();
    begin
        perform dash.sync_dims();
        begin
            perform dash.refresh(3);
            delete from dash.refresh_state where key = 'last_error';
        exception when others then
            v_dash := 'failed';
            insert into dash.refresh_state (key, value) values ('last_error', left(sqlerrm, 1000))
            on conflict (key) do update set value = excluded.value, updated_at = now();
        end;
        update ops.pipeline_run set gold_status = 'success', gold_error = null, gold_next_at = null,
               gold_seconds = round(extract(epoch from clock_timestamp() - v_t)::numeric, 2) where run_id = v.run_id;
        return jsonb_build_object('status', 'success', 'run_id', v.run_id, 'dash', v_dash);
    exception when others then
        v_att := v.gold_attempts + 1;
        update ops.pipeline_run
           set gold_status = 'failed', gold_error = left(sqlerrm, 1000), gold_attempts = v_att,
               gold_seconds = round(extract(epoch from clock_timestamp() - v_t)::numeric, 2),
               gold_next_at = case when v_att < 5 and silver.classify_error(sqlstate) = 'transient'
                                   then now() + make_interval(mins => silver.backoff_minutes(v_att)) end
         where run_id = v.run_id;
        return jsonb_build_object('status', 'failed', 'run_id', v.run_id, 'error', sqlerrm, 'attempt', v_att);
    end;
end $function$
;

drop table if exists dash.refresh_table_state;
delete from dash.cfg_threshold where key = 'gold_stale_minutes';
delete from silver.sidnl_config where key = 'gold_max_attempts';
delete from ops.function_backup where fn = 'silver.run_gold_pending()' and tag = 'pre_dash_006';

-- Verify: md5(pg_get_functiondef('silver.run_gold_pending()'::regprocedure)) = '9a20ecb50316dbe13293e239f7f0f55e'

-- ==================================================================== 20261110101147 silver_056_parse_pack_counts
-- Rollback for silver_056_parse_pack_counts.
-- 1. Restores silver.parse_pack and silver.selftest_parser to their exact pre-056 text (saved in ops.function_backup,
--    tag pre_silver_056).
-- 2. Re-derives size/unit/pack for silver.dim_product with the restored parser. Before 056 every row equalled
--    parse_pack(pack_raw), so this returns every row to its pre-056 values.
-- 3. Queues one forced pipeline job so canonical attributes, SI order and gold follow, exactly as 056 did.
-- Apply as a Supabase migration named silver_056r_rollback_parse_pack_counts if ever needed.

do $rb$
declare r record;
begin
    for r in select definition from ops.function_backup where tag = 'pre_silver_056' loop
        execute r.definition;
    end loop;
end $rb$;

update silver.dim_product d
   set size_value = pk.size_value, size_unit = pk.size_unit, pack_count = pk.pack_count
  from silver.dim_product d2 cross join lateral silver.parse_pack(d2.pack_raw) pk
 where d2.product_key = d.product_key
   and (d.size_value, d.size_unit, d.pack_count) is distinct from (pk.size_value, pk.size_unit, pk.pack_count);

insert into ops.pipeline_job (job_type, trigger, force, status) values ('regular', 'silver_056r', true, 'queued');

delete from ops.function_backup where tag = 'pre_silver_056';

-- Verify: md5(pg_get_functiondef('silver.parse_pack(text)'::regprocedure)) = '872db3fa441e361ed86a9bc376abb0b0'
--         md5(pg_get_functiondef('silver.selftest_parser()'::regprocedure)) = '55cc3161c925740a6a99a26f05bffdd0'

-- ==================================================================== 20261110102500 dash_007_visibility_full_rebuild
-- Rollback for dash_007_visibility_full_rebuild: restore run_gold_pending as of dash_006 (3-day visibility window).
-- Note: rolling back brings back stale SI ids in visibility rows older than 3 days after the next renumbering.
do $rb$
declare r record;
begin
    for r in select definition from ops.function_backup where tag = 'pre_dash_007' loop
        execute r.definition;
    end loop;
end $rb$;
delete from silver.sidnl_config where key = 'gold_visibility_days';
delete from ops.function_backup where tag = 'pre_dash_007';
-- Verify: md5(pg_get_functiondef('silver.run_gold_pending()'::regprocedure)) = 'c907f4c46b44829b836aeb54b93f6000'

-- ==================================================================== 20261110103405 silver_057_seen_dates_and_stale_review
-- Rollback for silver_057_seen_dates_and_stale_review.
update silver.dim_product d set first_seen_at = b.first_seen_at
  from ops.backup_silver_057 b where b.product_key = d.product_key;
update silver.match_review_queue set status = 'pending', decided_by = null, decided_at = null
 where status = 'rejected' and decided_by like 'system:silver_057%';
drop table ops.backup_silver_057;

-- ==================================================================== 20261110103437 silver_058_auto_exact_match
-- Rollback for silver_058_auto_exact_match.
-- Stops the job and removes the function. Merges it already made are split back with the existing
-- silver.unmap_product (each product gets its own new SI id; the pipeline resequences SI ids on its next run).
select cron.unschedule('sidnl-auto-match');
select silver.unmap_product(product_key, 'rollback:silver_058')
  from silver.product_xref where reviewed_by = 'auto:exact_name_size';
drop function if exists silver.auto_approve_exact_matches();
delete from silver.sidnl_config where key = 'auto_match_exact_enabled';
update ops.pipeline_run set gold_status = 'pending'
 where run_id = (select max(run_id) from ops.pipeline_run where status = 'success');

-- ==================================================================== 20261110103810 silver_059_maintenance_automation
-- Rollback for silver_059_maintenance_automation. (ANALYZE only refreshed statistics; nothing to undo.)
select cron.unschedule('sidnl-maintenance');
drop function if exists silver.run_maintenance();
delete from silver.sidnl_config where key = 'cron_history_keep_days';

-- ==================================================================== 20261110104140 dash_008_brand_scorecard
-- Rollback for dash_008_brand_scorecard (views only; no data).
drop view if exists dash.v_brand_scorecard_latest;
drop view if exists dash.v_brand_scorecard;

-- ==================================================================== 20261110104441 dash_009_brand_scorecard_fast
-- Rollback for dash_009_brand_scorecard_fast: re-apply the two view definitions from
-- migration dash_008_brand_scorecard (`select statements from supabase_migrations.schema_migrations
-- where name = 'dash_008_brand_scorecard'`) with "create view" changed to "create or replace view".
-- (Same output columns and numbers; only slower.)

-- ==================================================================== 20261110105523 silver_060_store_city_from_snapshots
-- Rollback for silver_060_store_city_from_snapshots.
select cron.unschedule('sidnl-store-city');
do $rb$ declare r record; begin
  for r in select definition from ops.function_backup where tag = 'pre_silver_060' loop execute r.definition; end loop;
end $rb$;
update silver.fact_shelf_position f set city_slug = null from ops.store_city_filled s where f.store_key = s.store_key;
update silver.fact_product_reading f set city_slug = null from ops.store_city_filled s where f.store_key = s.store_key;
update silver.dim_store d set city_slug = null from ops.store_city_filled s where d.store_key = s.store_key;
drop function if exists silver.fill_store_cities();
drop index if exists silver.ix_fsp_null_city;
drop index if exists silver.ix_reading_null_city;
drop table ops.store_city_filled;
delete from ops.function_backup where tag = 'pre_silver_060';
update ops.pipeline_run set gold_status = 'pending' where run_id = (select max(run_id) from ops.pipeline_run where status = 'success');

-- ==================================================================== 20261110105950 silver_061_reconciliation
-- Rollback for silver_061_reconciliation.
select cron.unschedule('sidnl-reconcile');
drop function if exists silver.reconcile();
drop view if exists ops.v_reconciliation_latest;
drop table if exists ops.reconciliation_log;
delete from silver.sidnl_config where key = 'reconcile_window_days';

-- ==================================================================== 20261110110726 silver_062_bronze_freshness
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

-- ==================================================================== 20261110112254 silver_063_dead_letter
-- Rollback for silver_063_dead_letter.
-- After rollback, rows that are 'open' in ops.dead_letter are no longer excluded: the next load retries them and, if
-- they still fail, the whole scope fails again (pre-063 behaviour). Export ops.dead_letter first if you need the history.
select cron.unschedule('sidnl-dead-letter');
select cron.unschedule('sidnl-reconcile-coverage');
do $rb$ declare r record; begin
  for r in select definition from ops.function_backup where tag = 'pre_silver_063' loop execute r.definition; end loop;
end $rb$;
drop function if exists silver.reconcile_coverage();
drop function if exists silver.ignore_dead_letter(bigint, text, text);
drop function if exists silver.retry_dead_letters(boolean);
drop function if exists silver.load_category_range(text, text, text, bigint, bigint, bigint);
drop function if exists silver.load_category_chunk(text, text, text, bigint, bigint, bigint);
drop view if exists ops.v_dead_letter_summary;
drop table if exists ops.dead_letter;
delete from silver.sidnl_config where key in ('dead_letter_max_per_chunk', 'dead_letter_retry_minutes', 'dead_letter_max_retries');
delete from ops.function_backup where tag = 'pre_silver_063';

-- == silver_064_heartbeat ==
drop view if exists ops.v_heartbeat;
drop function if exists silver.enqueue_daily_safe(p_reason text);
delete from silver.sidnl_config
 where key in ('heartbeat_pipeline_max_minutes', 'heartbeat_gold_max_minutes',
               'heartbeat_daily_max_hours', 'heartbeat_run_max_minutes');
-- if the sidnl-pipeline-daily command was updated (admin step 4), restore it:
--   select cron.unschedule('sidnl-pipeline-daily');
--   select cron.schedule('sidnl-pipeline-daily', '35 18 * * *',
--     'set statement_timeout=''600s''; select silver.enqueue_daily(''cron-daily'', false);');

-- == silver_065_alert_outbox ==
drop trigger if exists trg_cron_alert_outbox on ops.cron_alert_log;
drop trigger if exists trg_storage_alert_outbox on ops.storage_alert_log;
drop function if exists ops.cron_alert_to_outbox();
drop function if exists ops.storage_alert_to_outbox();
drop function if exists ops.alert_claim(p_limit int);
drop function if exists ops.alert_mark(p_alert_id bigint, p_ok bool, p_err text);
drop view if exists ops.v_alert_outbox_health;
drop table if exists ops.alert_outbox;
delete from silver.sidnl_config
 where key in ('alert_delivery_enabled', 'alert_max_attempts', 'alert_claim_timeout_minutes');
-- if the sidnl-alerts cron was added, also run:
--   select cron.unschedule('sidnl-alerts');
-- if pg_net was enabled only for this feature, also run:
--   drop extension if exists pg_net;
