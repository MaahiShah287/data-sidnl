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

-- ==================================================================== 20261110144308 dash_010_refresh_status_stale_means_behind
-- Restore the dash_006 definition of dash.v_refresh_status (is_stale = last success older than gold_stale_minutes) and the
-- original config description. Same columns, so nothing depends on it changing.
update dash.cfg_threshold
   set description = 'dash.v_refresh_status: a table counts as stale when its last successful refresh is older than this many minutes'
 where key = 'gold_stale_minutes';
create or replace view dash.v_refresh_status with (security_invoker = true) as
select s.table_name, s.last_refreshed_at, round(extract(epoch from now() - s.last_refreshed_at) / 60, 1) as age_minutes,
       s.row_count, s.last_status, s.last_attempt_at, s.last_error, s.gold_attempts, s.next_retry_at,
       (s.last_status = 'failed') as refresh_failing,
       (s.last_status = 'failed' and s.next_retry_at is null) as needs_attention,
       (s.last_refreshed_at is null
        or now() - s.last_refreshed_at > make_interval(mins => coalesce(
               (select c.value from dash.cfg_threshold c where c.key = 'gold_stale_minutes'), 180)::int)) as is_stale
from dash.refresh_table_state s;

-- ==================================================================== 20261110144713 silver_064_heartbeat
-- If the sidnl-pipeline-daily command was switched to silver.enqueue_daily_safe, switch it back first:
--   select cron.unschedule('sidnl-pipeline-daily');
--   select cron.schedule('sidnl-pipeline-daily', '35 18 * * *', 'select silver.enqueue_daily(''cron-daily'', false)');
drop function if exists ops.heartbeat();
drop function if exists silver.enqueue_daily_safe(text);
drop view if exists ops.v_heartbeat;
delete from silver.sidnl_config where key in ('heartbeat_pipeline_max_minutes', 'heartbeat_gold_max_minutes', 'heartbeat_daily_max_hours');
-- (grant usage on schema ops to service_role is shared with silver_065; revoke it only after both are rolled back:
--  revoke usage on schema ops from service_role;)

-- ==================================================================== 20261110144717 silver_065_alert_outbox
-- If the delivery cron was scheduled: select cron.unschedule('sidnl-alerts');
drop trigger if exists trg_cron_alert_outbox on ops.cron_alert_log;
drop trigger if exists trg_storage_alert_outbox on ops.storage_alert_log;
drop function if exists ops.cron_alert_to_outbox();
drop function if exists ops.storage_alert_to_outbox();
drop function if exists ops.alert_claim(int);
drop function if exists ops.alert_mark(bigint, bool, text);
drop view if exists ops.v_alert_outbox_health;
drop table if exists ops.alert_outbox;   -- undelivered alerts in it are lost; the source rows stay in the alert log tables
delete from silver.sidnl_config where key in ('alert_delivery_enabled', 'alert_max_attempts', 'alert_claim_timeout_minutes');

-- ==================================================================== 20261110145747 silver_066_alert_delivery
select cron.unschedule('sidnl-alerts');
drop function if exists silver.deliver_alerts();
drop function if exists silver.send_test_alert();
drop function if exists silver.slack_text(text, text, text, text);
alter table ops.alert_outbox drop column if exists request_id;
-- pg_net is left installed (other things may use it); to remove: drop extension pg_net;
-- The Vault secret slack_webhook_url is not touched; to remove it: delete from vault.secrets where name = 'slack_webhook_url';

-- ==================================================================== 20261110150218 silver_067_heartbeat_endpoint
drop function if exists public.sidnl_heartbeat(text);
-- The Vault secret heartbeat_token (created by the owner) is not touched; remove with: delete from vault.secrets where name = 'heartbeat_token';

-- ==================================================================== 20261110150321 silver_068_daily_lock_safe
select cron.alter_job(job_id := (select jobid from cron.job where jobname = 'sidnl-pipeline-daily'),
                      command := $cmd$select silver.enqueue_daily('cron-daily', false)$cmd$);

-- ==================================================================== 20261111063634 silver_069_bronze_column_contract
-- Re-adds the removed columns and refills them from bronze (store_weight was never written: it comes back empty).
alter table silver.dim_city add column if not exists center_lat double precision, add column if not exists center_lon double precision;
update silver.dim_city d set center_lat = c.center_lat, center_lon = c.center_lon from public.cities c where c.slug = d.city_slug;
alter table silver.dim_store add column if not exists "store_weight (weight per store, e.g. store sales)" numeric;
alter table silver.fact_store_scan add column if not exists pages_read integer;
update silver.fact_store_scan f set pages_read = s.pages_read from public.search_snapshots s where s.id = f.snapshot_id;
CREATE OR REPLACE FUNCTION silver.dq_status(p_flags text[])
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
    select case
        when p_flags && array['no_product','no_store','bad_timestamp','unknown_state',
                              'negative_inventory','negative_price'] then 'invalid'
        when p_flags && array['sp_gt_mrp','mrp_missing','oos_with_inventory',
                              'price_missing_in_stock'] then 'suspect'
        else 'valid' end
$function$
;

CREATE OR REPLACE FUNCTION silver.load_category_chunk(p_platform text, p_l1 text, p_l2 text, p_lo bigint, p_hi bigint, p_run bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare v_ins int; v_upd int; v_new_stores int; v_p jsonb;
begin
        with ins as (
            insert into silver.dim_store (platform, store_external_id, source_store_id, store_name, city_slug,
                                          latitude, longitude, first_seen_at, last_seen_at)
            select s.platform, s.external_id, s.id, s.name, s.city_slug, s.lat, s.lon, s.first_seen_at, s.last_seen_at
            from public.stores s
            where s.id in (
                    select distinct coalesce(sp.store_id, sn.store_id)
                    from public.shelf_positions sp
                    join public.shelf_snapshots sn on sn.id = sp.snapshot_id
                    where sp.id > p_lo and sp.id <= p_hi and sn.status = 'ok'
                      and sn.platform = p_platform and sn.l1_id = p_l1 and sn.l2_id = p_l2)
              and s.platform in (select platform from silver.dim_platform)
            on conflict (source_store_id) do nothing
            returning 1)
        select count(*) into v_new_stores from ins;

        with src as materialized (
            select sp.id, sp.snapshot_id, sn.platform, sn.l1_id, sn.l2_id, coalesce(sp.store_id, sn.store_id) as src_store,
                   sn.taken_at, sp."position" as pos, sp.organic_position as opos, sp.is_ad, sp.ad_type, pp.brand,
                   sp.external_id, pp.name, pp.pack, sp.state, sp.inventory, sp.inventory_capped,
                   sp.price::numeric as price, sp.mrp::numeric as mrp,
                   sn.cards_seen, sn.total_items, sn.complete
            from public.shelf_positions sp
            join public.shelf_snapshots sn on sn.id = sp.snapshot_id
            left join public.platform_products pp on pp.platform = sn.platform and pp.external_id = sp.external_id
            join silver.dim_platform dpl on dpl.platform = sn.platform and not dpl.is_test
            where sp.id > p_lo and sp.id <= p_hi and sn.status = 'ok'
              and sn.platform = p_platform and sn.l1_id = p_l1 and sn.l2_id = p_l2
              and not exists (select 1 from ops.dead_letter dl
                               where dl.status = 'open' and dl.source_table = 'public.shelf_positions' and dl.bronze_id = sp.id)
        ), bm as materialized (
            select x.b as raw_brand,
                   (select sb.brand_key from silver.brand_scope sb
                     where sb.is_enabled and silver.brand_matches(sb.brand_key, x.b)
                     order by sb.brand_key limit 1) as client_key
            from (select distinct brand as b from src where brand is not null) x
            offset 0
        ), ins as (
            insert into silver.fact_shelf_position as t (
                source_record_id, snapshot_id, platform, l1_id, l2_id, store_key, city_slug, observed_at, shelf_position,
                organic_position, is_ad, ad_type, brand_raw, brand_key, is_client_brand, platform_product_id, product_name,
                pack_raw, stock_status, inventory_units, inventory_is_capped, selling_price, mrp,
                shelf_cards_seen, shelf_total_items, shelf_complete, dq_status, dq_flags, etl_run_id)
            select s.id, s.snapshot_id, s.platform, s.l1_id, s.l2_id, ds.store_key, ds.city_slug, s.taken_at, s.pos, s.opos,
                   s.is_ad, s.ad_type, s.brand,
                   coalesce(bm.client_key, case when s.brand is null then null else nullif(silver.norm_key(s.brand), '') end, '(unknown)'),
                   bm.client_key is not null,
                   s.external_id, s.name, s.pack,
                   q.status, s.inventory, coalesce(s.inventory_capped, false), round(s.price, 2), round(s.mrp, 2),
                   s.cards_seen, s.total_items, s.complete, silver.dq_status(q.flags), q.flags, p_run
            from src s
            left join bm on bm.raw_brand = s.brand
            left join silver.dim_store ds on ds.source_store_id = s.src_store
            cross join lateral (
                select silver.map_stock_status(s.state) as status,
                       silver.reading_dq(true, ds.store_key is not null, s.taken_at, silver.map_stock_status(s.state),
                                         s.inventory, round(s.price, 2), round(s.mrp, 2)) as flags) q
            on conflict (source_record_id) do update set
                snapshot_id = excluded.snapshot_id, store_key = excluded.store_key, city_slug = excluded.city_slug,
                observed_at = excluded.observed_at, shelf_position = excluded.shelf_position,
                organic_position = excluded.organic_position, is_ad = excluded.is_ad, ad_type = excluded.ad_type,
                brand_raw = excluded.brand_raw, brand_key = excluded.brand_key, is_client_brand = excluded.is_client_brand,
                platform_product_id = excluded.platform_product_id, product_name = excluded.product_name,
                pack_raw = excluded.pack_raw, stock_status = excluded.stock_status, inventory_units = excluded.inventory_units,
                inventory_is_capped = excluded.inventory_is_capped, selling_price = excluded.selling_price, mrp = excluded.mrp,
                shelf_cards_seen = excluded.shelf_cards_seen, shelf_total_items = excluded.shelf_total_items,
                shelf_complete = excluded.shelf_complete, dq_status = excluded.dq_status, dq_flags = excluded.dq_flags,
                loaded_at = now(), etl_run_id = excluded.etl_run_id
            where (t.snapshot_id, t.store_key, t.city_slug, t.observed_at, t.shelf_position, t.organic_position, t.is_ad, t.ad_type,
                   t.brand_raw, t.brand_key, t.is_client_brand, t.platform_product_id, t.product_name, t.pack_raw, t.stock_status,
                   t.inventory_units, t.inventory_is_capped, t.selling_price, t.mrp, t.shelf_cards_seen, t.shelf_total_items,
                   t.shelf_complete, t.dq_status, t.dq_flags)
                  is distinct from
                  (excluded.snapshot_id, excluded.store_key, excluded.city_slug, excluded.observed_at, excluded.shelf_position,
                   excluded.organic_position, excluded.is_ad, excluded.ad_type, excluded.brand_raw, excluded.brand_key,
                   excluded.is_client_brand, excluded.platform_product_id, excluded.product_name, excluded.pack_raw,
                   excluded.stock_status, excluded.inventory_units, excluded.inventory_is_capped, excluded.selling_price,
                   excluded.mrp, excluded.shelf_cards_seen, excluded.shelf_total_items, excluded.shelf_complete,
                   excluded.dq_status, excluded.dq_flags)
            returning (xmax = 0) as inserted)
        select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;

        v_p := silver.refresh_category_products(p_run, p_lo, p_hi);

        return jsonb_build_object('stores', v_new_stores, 'ins', v_ins, 'upd', v_upd,
                                  'pb', (v_p ->> 'brands')::int, 'pi', (v_p ->> 'ins')::int,
                                  'pu', (v_p ->> 'upd')::int, 'pl', (v_p ->> 'linked')::int, 'dead_lettered', 0);
end $function$
;

CREATE OR REPLACE FUNCTION silver.refresh_category_market(p_full boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare
    sc record; v_key text; v_s jsonb; v_scopes jsonb := '{}'::jsonb; v_failed jsonb := '[]'::jsonb;
    v_ins bigint := 0; v_upd bigint := 0;
begin
    insert into silver.dim_city (city_slug, city_name, state, center_lat, center_lon)
    select c.slug, c.name, c.state, c.center_lat, c.center_lon from public.cities c
    on conflict (city_slug) do update set
        city_name = excluded.city_name, state = excluded.state,
        center_lat = excluded.center_lat, center_lon = excluded.center_lon
    where (silver.dim_city.city_name, silver.dim_city.state, silver.dim_city.center_lat, silver.dim_city.center_lon)
          is distinct from (excluded.city_name, excluded.state, excluded.center_lat, excluded.center_lon);

    for sc in select platform, l1_id, l2_id from silver.category_scope where is_enabled order by 1, 2, 3 loop
        v_key := sc.platform || '/' || sc.l1_id || '/' || sc.l2_id;
        begin
            v_s := silver.refresh_category_scope(sc.platform, sc.l1_id, sc.l2_id, p_full);
            v_scopes := v_scopes || jsonb_build_object(v_key, v_s || jsonb_build_object('ok', true));
            v_ins := v_ins + coalesce((v_s -> 'fact_shelf_position' ->> 'inserted')::bigint, 0);
            v_upd := v_upd + coalesce((v_s -> 'fact_shelf_position' ->> 'updated')::bigint, 0);
        exception when others then
            v_failed := v_failed || to_jsonb(v_key);
            v_scopes := v_scopes || jsonb_build_object(v_key, jsonb_build_object('ok', false, 'error', sqlerrm, 'sqlstate', sqlstate));
            update silver.category_scope set last_status = 'failed', last_error = left(sqlerrm, 500),
                   consecutive_failures = consecutive_failures + 1
             where platform = sc.platform and l1_id = sc.l1_id and l2_id = sc.l2_id;
        end;
    end loop;
    return jsonb_build_object('mode', case when p_full then 'full' else 'incremental' end,
                              'scopes', v_scopes, 'failed_scopes', v_failed,
                              'fact_shelf_position', jsonb_build_object('inserted', v_ins, 'updated', v_upd));
end $function$
;

CREATE OR REPLACE FUNCTION silver.refresh_brand(p_brand_key text DEFAULT 'mr munchies'::text, p_full boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare
    v_scope  silver.brand_scope%rowtype;
    v_run    bigint;
    v_stats  jsonb := '{}'::jsonb;
    v_ins    int;
    v_upd    int;
    v_full   boolean;
    v_lb     bigint := coalesce(silver.cfg('incremental_lookback_rows'), 5000)::bigint;
    w_obs bigint := 0; w_sc bigint := 0; w_sp bigint := 0; w_ssn bigint := 0;
begin
    select * into v_scope from silver.brand_scope where brand_key = p_brand_key;
    if not found then
        raise exception 'unknown brand_key "%": add it to silver.brand_scope first', p_brand_key;
    end if;
    if not v_scope.is_enabled then
        raise exception 'brand "%" is disabled in silver.brand_scope', p_brand_key;
    end if;

    v_full := p_full or not exists (select 1 from ops.etl_run where brand_key = p_brand_key and status = 'success');
    if not v_full then
        select coalesce(greatest(max(last_seen_id) filter (where source_table = 'observations')     - v_lb, 0), 0),
               coalesce(greatest(max(last_seen_id) filter (where source_table = 'search_cards')      - v_lb, 0), 0),
               coalesce(greatest(max(last_seen_id) filter (where source_table = 'shelf_positions')   - v_lb, 0), 0),
               coalesce(greatest(max(last_seen_id) filter (where source_table = 'search_snapshots')  - v_lb, 0), 0)
          into w_obs, w_sc, w_sp, w_ssn
          from silver.pipeline_source where source_schema = 'public';
    end if;

    insert into ops.etl_run (brand_key) values (p_brand_key) returning run_id into v_run;

    drop table if exists _brand_strings, _listings, _raw, _store_ids, _scans,
                         _cat_src, _cat_best, _prod_src, _prod;

    perform silver.refresh_brand_strings(v_full);

    insert into silver.dim_city (city_slug, city_name, state, center_lat, center_lon)
    select c.slug, c.name, c.state, c.center_lat, c.center_lon from public.cities c
    on conflict (city_slug) do update set
        city_name = excluded.city_name, state = excluded.state,
        center_lat = excluded.center_lat, center_lon = excluded.center_lon
    where (silver.dim_city.city_name, silver.dim_city.state, silver.dim_city.center_lat, silver.dim_city.center_lon)
          is distinct from (excluded.city_name, excluded.state, excluded.center_lat, excluded.center_lon);

    insert into silver.dim_brand (brand_key, brand_name, company_name, is_tracked)
    values (v_scope.brand_key, v_scope.brand_name, v_scope.company_name, true)
    on conflict (brand_key) do update set
        brand_name = excluded.brand_name, company_name = excluded.company_name
    where (silver.dim_brand.brand_name, silver.dim_brand.company_name)
          is distinct from (excluded.brand_name, excluded.company_name);

    create temp table _brand_strings on commit drop as
    select raw_brand as b from silver.brand_string_registry
    where silver.brand_matches(p_brand_key, raw_brand);

    create temp table _listings on commit drop as
    select pl.id                                   as listing_id,
           pl.platform,
           pl.external_id,
           coalesce(pl.name, p.name)               as name,
           coalesce(pl.brand, p.brand)             as brand,
           pl.pack_size,
           coalesce(pl.image_url, p.image_url)     as image_url,
           pl.url,
           pl.product_id                           as catalog_product_id,
           pl.categories::jsonb                    as categories
    from public.platform_listings pl
    join public.products p on p.id = pl.product_id
    where coalesce(pl.brand, p.brand) in (select b from _brand_strings)
      and pl.platform in (select platform from silver.dim_platform where not is_test);

    create temp table _scans on commit drop as
    select ss.*
    from public.search_snapshots ss
    join public.brand_scrapes bs on bs.id = ss.scrape_id
    where ss.id > w_ssn
      and ss.platform in (select platform from silver.dim_platform where not is_test)
      and exists (select 1
                  from json_array_elements_text(
                           case when json_typeof(bs.brands) = 'array' then bs.brands else '[]'::json end) x(v)
                  where silver.brand_matches(p_brand_key, x.v));

    create temp table _raw on commit drop as
    select 'stock_check'::text            as source_type,
           'public.observations'::text    as source_table,
           o.id                           as source_record_id,
           l.platform,
           l.external_id                  as platform_product_id,
           o.store_id                     as src_store_id,
           null::int                      as planned_store_id,
           ('stock_check:' || o.run_id)   as job_ref,
           o.run_id::int                  as run_id,
           null::int                      as scrape_id,
           null::bigint                   as snapshot_id,
           l.listing_id                   as listing_id,
           o.observed_at,
           o.state,
           o.inventory,
           o.inventory_capped,
           o.price::numeric               as price,
           o.mrp::numeric                 as mrp,
           null::int                      as pos,
           null::int                      as opos,
           null::boolean                  as is_ad,
           null::text                     as ad_type,
           null::text                     as ptype,
           null::text                     as name,
           null::text                     as brand,
           null::text                     as pack,
           null::text                     as image_url
    from public.observations o
    join _listings l on l.listing_id = o.listing_id
    where o.id > w_obs

    union all
    select 'brand_search', 'public.search_cards', c.id,
           ss.platform, c.external_id,
           coalesce(c.store_id, ss.store_id, ss.planned_store_id),
           ss.planned_store_id,
           ('brand_scrape:' || ss.scrape_id),
           null::int, ss.scrape_id::int, ss.id::bigint, null::int,
           ss.taken_at, c.state, c.inventory, c.inventory_capped,
           c.price::numeric, c.mrp::numeric,
           c."position", c.organic_position, c.is_ad, null::text,
           pp.ptype, pp.name, pp.brand, pp.pack, pp.image_url
    from public.search_cards c
    join public.search_snapshots ss on ss.id = c.snapshot_id
    join public.platform_products pp on pp.platform = ss.platform and pp.external_id = c.external_id
    where c.id > w_sc
      and pp.brand in (select b from _brand_strings)
      and ss.platform in (select platform from silver.dim_platform where not is_test)

    union all
    select 'category_shelf', 'public.shelf_positions', sp.id,
           sn.platform, sp.external_id,
           coalesce(sp.store_id, sn.store_id),
           sn.store_id,
           case when sn.sweep_id is not null then 'category_sweep:' || sn.sweep_id
                else 'shelf_snapshot:' || sn.id end,
           null::int, null::int, sn.id::bigint, null::int,
           sn.taken_at, sp.state, sp.inventory, sp.inventory_capped,
           sp.price::numeric, sp.mrp::numeric,
           sp."position", sp.organic_position, sp.is_ad, sp.ad_type,
           pp.ptype, pp.name, pp.brand, pp.pack, pp.image_url
    from public.shelf_positions sp
    join public.shelf_snapshots sn on sn.id = sp.snapshot_id
    join public.platform_products pp on pp.platform = sn.platform and pp.external_id = sp.external_id
    where sp.id > w_sp
      and pp.brand in (select b from _brand_strings)
      and sn.platform in (select platform from silver.dim_platform where not is_test);

    create temp table _store_ids on commit drop as
    select src_store_id as id from _raw where src_store_id is not null
    union select planned_store_id from _raw where planned_store_id is not null
    union select store_id from _scans where store_id is not null
    union select planned_store_id from _scans where planned_store_id is not null;

    with ins as (
        insert into silver.dim_store (platform, store_external_id, source_store_id, store_name,
                                      city_slug, latitude, longitude, first_seen_at, last_seen_at)
        select s.platform, s.external_id, s.id, s.name, s.city_slug, s.lat, s.lon,
               s.first_seen_at, s.last_seen_at
        from public.stores s
        where s.id in (select id from _store_ids)
          and s.platform in (select platform from silver.dim_platform)
        on conflict (source_store_id) do update set
            store_name = excluded.store_name, city_slug = coalesce(excluded.city_slug, silver.dim_store.city_slug),
            latitude = excluded.latitude, longitude = excluded.longitude,
            first_seen_at = excluded.first_seen_at, last_seen_at = excluded.last_seen_at
        where (silver.dim_store.store_name, silver.dim_store.city_slug, silver.dim_store.latitude, silver.dim_store.longitude, silver.dim_store.first_seen_at, silver.dim_store.last_seen_at)
              is distinct from (excluded.store_name, coalesce(excluded.city_slug, silver.dim_store.city_slug), excluded.latitude, excluded.longitude, excluded.first_seen_at, excluded.last_seen_at)
        returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;
    v_stats := v_stats || jsonb_build_object('dim_store', jsonb_build_object('inserted', v_ins, 'updated', v_upd));

    create temp table _cat_src on commit drop as
    select l.platform, l.external_id as platform_product_id, 1 as prio,
           l.categories -> 0 ->> 'id'   as l1_id, l.categories -> 0 ->> 'name' as l1_name,
           l.categories -> 1 ->> 'id'   as l2_id, l.categories -> 1 ->> 'name' as l2_name,
           l.categories -> 2 ->> 'id'   as l3_id, l.categories -> 2 ->> 'name' as l3_name
    from _listings l
    where jsonb_typeof(l.categories) = 'array' and jsonb_array_length(l.categories) >= 1
    union all
    select pc.platform::text, pc.product_id::text, 2,
           pc.category_l1_id::text, c.category_l1,
           pc.category_l2_id::text, c.category_l2,
           null, null
    from analytics.product_categories pc
    left join analytics.categories c
           on c.platform = pc.platform
          and c.category_l1_id = pc.category_l1_id
          and c.category_l2_id = pc.category_l2_id
    where (pc.platform::text, pc.product_id::text) in
          (select platform, platform_product_id from _raw);

    create temp table _cat_best on commit drop as
    select distinct on (platform, platform_product_id)
           platform, platform_product_id, l1_id, l1_name, l2_id, l2_name, l3_id, l3_name
    from _cat_src
    where l1_name is not null
    order by platform, platform_product_id, prio;

    insert into silver.dim_category (platform, l1_id, l1_name, l2_id, l2_name, l3_id, l3_name)
    select distinct platform, l1_id, l1_name, l2_id, l2_name, l3_id, l3_name from _cat_best
    on conflict do nothing;

    create temp table _prod_src on commit drop as
    select l.platform, l.external_id as pid, 1 as prio, now() as seen_at,
           l.name, l.brand, l.pack_size as pack, null::text as ptype, l.image_url, l.url,
           l.listing_id, l.catalog_product_id
    from _listings l
    union all
    select r.platform, r.platform_product_id, case r.source_type when 'brand_search' then 2 else 3 end,
           r.observed_at, r.name, r.brand, r.pack, r.ptype, r.image_url, null::text, null::int, null::int
    from _raw r where r.source_type <> 'stock_check';

    create temp table _prod on commit drop as
    select platform, pid,
           (array_agg(name       order by prio, seen_at desc) filter (where name is not null))[1]       as name,
           (array_agg(brand      order by prio, seen_at desc) filter (where brand is not null))[1]      as brand,
           (array_agg(pack       order by prio, seen_at desc) filter (where pack is not null))[1]       as pack,
           (array_agg(ptype      order by prio, seen_at desc) filter (where ptype is not null))[1]      as ptype,
           (array_agg(image_url  order by prio, seen_at desc) filter (where image_url is not null))[1]  as image_url,
           (array_agg(url        order by prio, seen_at desc) filter (where url is not null))[1]        as url,
           (array_agg(listing_id order by prio, seen_at desc) filter (where listing_id is not null))[1] as listing_id,
           (array_agg(catalog_product_id order by prio, seen_at desc)
                                                              filter (where catalog_product_id is not null))[1] as catalog_product_id
    from _prod_src
    group by platform, pid;

    with ins as (
        insert into silver.dim_product (platform, platform_product_id, brand_key, product_name, variant,
                                        product_type, pack_raw, size_value, size_unit, pack_count,
                                        category_key, listing_id, catalog_product_id, image_url, product_url)
        select p.platform, p.pid, p_brand_key,
               coalesce(p.name, 'Unknown product ' || p.pid),
               silver.parse_variant(p.name, p.brand, p.ptype),
               p.ptype, p.pack, pk.size_value, pk.size_unit, pk.pack_count,
               dc.category_key, p.listing_id, p.catalog_product_id, p.image_url, p.url
        from _prod p
        cross join lateral silver.parse_pack(p.pack) pk
        left join _cat_best cb on cb.platform = p.platform and cb.platform_product_id = p.pid
        left join silver.dim_category dc
               on dc.platform = cb.platform
              and dc.l1_id   is not distinct from cb.l1_id   and dc.l1_name is not distinct from cb.l1_name
              and dc.l2_id   is not distinct from cb.l2_id   and dc.l2_name is not distinct from cb.l2_name
              and dc.l3_id   is not distinct from cb.l3_id   and dc.l3_name is not distinct from cb.l3_name
        on conflict (platform, platform_product_id) do update set
            brand_key = excluded.brand_key, product_name = excluded.product_name,
            variant = excluded.variant, product_type = coalesce(excluded.product_type, silver.dim_product.product_type),
            pack_raw = excluded.pack_raw, size_value = excluded.size_value, size_unit = excluded.size_unit,
            pack_count = excluded.pack_count,
            category_key = coalesce(excluded.category_key, silver.dim_product.category_key),
            listing_id = coalesce(excluded.listing_id, silver.dim_product.listing_id),
            catalog_product_id = coalesce(excluded.catalog_product_id, silver.dim_product.catalog_product_id),
            image_url = coalesce(excluded.image_url, silver.dim_product.image_url),
            product_url = coalesce(excluded.product_url, silver.dim_product.product_url)
        where (silver.dim_product.brand_key, silver.dim_product.product_name, silver.dim_product.variant, silver.dim_product.product_type,
               silver.dim_product.pack_raw, silver.dim_product.size_value, silver.dim_product.size_unit, silver.dim_product.pack_count,
               silver.dim_product.category_key, silver.dim_product.listing_id, silver.dim_product.catalog_product_id,
               silver.dim_product.image_url, silver.dim_product.product_url)
              is distinct from
              (excluded.brand_key, excluded.product_name, excluded.variant, coalesce(excluded.product_type, silver.dim_product.product_type),
               excluded.pack_raw, excluded.size_value, excluded.size_unit, excluded.pack_count,
               coalesce(excluded.category_key, silver.dim_product.category_key), coalesce(excluded.listing_id, silver.dim_product.listing_id),
               coalesce(excluded.catalog_product_id, silver.dim_product.catalog_product_id),
               coalesce(excluded.image_url, silver.dim_product.image_url), coalesce(excluded.product_url, silver.dim_product.product_url))
        returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;
    v_stats := v_stats || jsonb_build_object('dim_product', jsonb_build_object('inserted', v_ins, 'updated', v_upd));

    with ins as (
        insert into silver.fact_product_reading (
            source_type, source_table, source_record_id, product_key, store_key, planned_store_key,
            city_slug, job_ref, run_id, scrape_id, snapshot_id, listing_id, observed_at,
            stock_state_raw, stock_status, is_listed, is_available, inventory_units, inventory_is_capped,
            selling_price, mrp, search_position, organic_position, is_ad, ad_type,
            osa_eligible, dq_status, dq_flags, etl_run_id)
        select r.source_type, r.source_table, r.source_record_id, dp.product_key, ds.store_key, dps.store_key,
               ds.city_slug, r.job_ref, r.run_id, r.scrape_id, r.snapshot_id, r.listing_id, r.observed_at,
               r.state, q.status, q.status <> 'not_listed',
               case q.status when 'in_stock' then true when 'out_of_stock' then false end,
               r.inventory, coalesce(r.inventory_capped, false),
               round(r.price, 2), round(r.mrp, 2), r.pos, r.opos, r.is_ad, r.ad_type,
               (r.source_type = 'stock_check' and q.status in ('in_stock', 'out_of_stock')
                                              and silver.dq_status(q.flags) = 'valid'),
               silver.dq_status(q.flags), q.flags, v_run
        from _raw r
        join silver.dim_product dp on dp.platform = r.platform and dp.platform_product_id = r.platform_product_id
        left join silver.dim_store ds  on ds.source_store_id  = r.src_store_id
        left join silver.dim_store dps on dps.source_store_id = r.planned_store_id
        cross join lateral (
            select silver.map_stock_status(r.state) as status,
                   silver.reading_dq(true, ds.store_key is not null, r.observed_at,
                                     silver.map_stock_status(r.state), r.inventory,
                                     round(r.price, 2), round(r.mrp, 2)) as flags) q
        on conflict (source_type, source_record_id) do update set
            product_key = excluded.product_key, store_key = excluded.store_key,
            planned_store_key = excluded.planned_store_key, city_slug = excluded.city_slug,
            job_ref = excluded.job_ref, run_id = excluded.run_id, scrape_id = excluded.scrape_id,
            snapshot_id = excluded.snapshot_id, listing_id = excluded.listing_id,
            observed_at = excluded.observed_at, stock_state_raw = excluded.stock_state_raw,
            stock_status = excluded.stock_status, is_listed = excluded.is_listed,
            is_available = excluded.is_available, inventory_units = excluded.inventory_units,
            inventory_is_capped = excluded.inventory_is_capped, selling_price = excluded.selling_price,
            mrp = excluded.mrp, search_position = excluded.search_position,
            organic_position = excluded.organic_position, is_ad = excluded.is_ad, ad_type = excluded.ad_type,
            osa_eligible = excluded.osa_eligible, dq_status = excluded.dq_status, dq_flags = excluded.dq_flags,
            loaded_at = now(), etl_run_id = excluded.etl_run_id
        where (silver.fact_product_reading.product_key, silver.fact_product_reading.store_key, silver.fact_product_reading.planned_store_key,
               silver.fact_product_reading.city_slug, silver.fact_product_reading.job_ref, silver.fact_product_reading.run_id,
               silver.fact_product_reading.scrape_id, silver.fact_product_reading.snapshot_id, silver.fact_product_reading.listing_id,
               silver.fact_product_reading.observed_at, silver.fact_product_reading.stock_state_raw, silver.fact_product_reading.stock_status,
               silver.fact_product_reading.is_listed, silver.fact_product_reading.is_available, silver.fact_product_reading.inventory_units,
               silver.fact_product_reading.inventory_is_capped, silver.fact_product_reading.selling_price, silver.fact_product_reading.mrp,
               silver.fact_product_reading.search_position, silver.fact_product_reading.organic_position, silver.fact_product_reading.is_ad,
               silver.fact_product_reading.ad_type, silver.fact_product_reading.osa_eligible, silver.fact_product_reading.dq_status,
               silver.fact_product_reading.dq_flags)
              is distinct from
              (excluded.product_key, excluded.store_key, excluded.planned_store_key, excluded.city_slug, excluded.job_ref, excluded.run_id,
               excluded.scrape_id, excluded.snapshot_id, excluded.listing_id, excluded.observed_at, excluded.stock_state_raw, excluded.stock_status,
               excluded.is_listed, excluded.is_available, excluded.inventory_units, excluded.inventory_is_capped, excluded.selling_price, excluded.mrp,
               excluded.search_position, excluded.organic_position, excluded.is_ad, excluded.ad_type, excluded.osa_eligible, excluded.dq_status,
               excluded.dq_flags)
        returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;
    v_stats := v_stats || jsonb_build_object('fact_product_reading', jsonb_build_object('inserted', v_ins, 'updated', v_upd));

    with ins as (
        insert into silver.fact_store_scan (
            snapshot_id, scrape_id, scrape_query, platform, brand_key, store_key, planned_store_key,
            city_slug, scanned_at, scan_status, pages_read, cards_seen, brand_cards_matched,
            is_complete, stopped_early, is_valid_denominator, dq_flags, etl_run_id)
        select s.id, s.scrape_id, bs.query, s.platform, p_brand_key, ds.store_key, dps.store_key,
               coalesce(ds.city_slug, dps.city_slug), s.taken_at, s.status, s.pages_read, s.cards_seen,
               s.cards_matched, s.complete, s.stopped_early,
               (s.status = 'ok' and ds.store_key is not null),
               array_remove(array[
                   case when ds.store_key is null then 'no_store' end,
                   case when s.status <> 'ok' then 'scan_' || s.status end,
                   case when s.store_id is not null and s.store_id is distinct from s.planned_store_id
                        then 'info_store_differs_from_planned' end], null),
               v_run
        from _scans s
        left join public.brand_scrapes bs on bs.id = s.scrape_id
        left join silver.dim_store ds  on ds.source_store_id  = s.store_id
        left join silver.dim_store dps on dps.source_store_id = s.planned_store_id
        on conflict (snapshot_id) do update set
            scrape_query = excluded.scrape_query, store_key = excluded.store_key,
            planned_store_key = excluded.planned_store_key, city_slug = excluded.city_slug,
            scanned_at = excluded.scanned_at, scan_status = excluded.scan_status,
            pages_read = excluded.pages_read, cards_seen = excluded.cards_seen,
            brand_cards_matched = excluded.brand_cards_matched, is_complete = excluded.is_complete,
            stopped_early = excluded.stopped_early, is_valid_denominator = excluded.is_valid_denominator,
            dq_flags = excluded.dq_flags, loaded_at = now(), etl_run_id = excluded.etl_run_id
        where (silver.fact_store_scan.scrape_query, silver.fact_store_scan.store_key, silver.fact_store_scan.planned_store_key,
               silver.fact_store_scan.city_slug, silver.fact_store_scan.scanned_at, silver.fact_store_scan.scan_status, silver.fact_store_scan.pages_read,
               silver.fact_store_scan.cards_seen, silver.fact_store_scan.brand_cards_matched, silver.fact_store_scan.is_complete,
               silver.fact_store_scan.stopped_early, silver.fact_store_scan.dq_flags)
              is distinct from
              (excluded.scrape_query, excluded.store_key, excluded.planned_store_key, excluded.city_slug, excluded.scanned_at, excluded.scan_status,
               excluded.pages_read, excluded.cards_seen, excluded.brand_cards_matched, excluded.is_complete, excluded.stopped_early, excluded.dq_flags)
        returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;
    v_stats := v_stats || jsonb_build_object('fact_store_scan', jsonb_build_object('inserted', v_ins, 'updated', v_upd));

    update silver.dim_product p
       set first_seen_at = x.mn, last_seen_at = x.mx
      from (select f.product_key, min(f.observed_at) mn, max(f.observed_at) mx
              from silver.fact_product_reading f
             where f.product_key in (select dp.product_key
                                       from silver.dim_product dp
                                       join _prod t on t.platform = dp.platform and t.pid = dp.platform_product_id)
             group by f.product_key) x
     where x.product_key = p.product_key
       and (p.first_seen_at, p.last_seen_at) is distinct from (x.mn, x.mx);

    v_stats := v_stats || jsonb_build_object('brand_key', p_brand_key, 'run_id', v_run, 'mode',
                                             case when v_full then 'full' else 'incremental' end);
    if v_full then
        v_stats := v_stats || jsonb_build_object(
            'dq', (select coalesce(jsonb_object_agg(dq_status, n), '{}'::jsonb)
                     from (select f.dq_status, count(*) n
                             from silver.fact_product_reading f
                             join silver.dim_product p using (product_key)
                            where p.brand_key = p_brand_key group by 1) d));
    end if;

    update ops.etl_run set finished_at = now(), status = 'success', stats = v_stats where run_id = v_run;
    return v_stats;
end
$function$
;

drop function if exists silver.backfill_read_flags(integer);
drop index if exists silver.ix_fsp_incomplete_oos;
-- rows flagged by silver_069 get their previous flags back on the next full reload:
--   select silver.run_pipeline(true, 'rollback-069');
alter table silver.fact_product_reading
    drop column if exists read_status, drop column if exists read_complete, drop column if exists max_allowed_quantity,
    drop column if exists pack_size_seen, drop column if exists store_role, drop column if exists matched_by,
    drop column if exists variant_of;
alter table silver.fact_store_scan
    drop column if exists search_query, drop column if exists latitude, drop column if exists longitude,
    drop column if exists scan_error;
drop function if exists silver.read_stock_status(text, text, boolean, boolean);
drop function if exists silver.read_flags(text, boolean, boolean);
drop function if exists silver.safe_int(text);
delete from silver.sidnl_config where key = 'exclude_incomplete_reads';

-- ==================================================================== 20261111063853 silver_070_scrape_context
-- (dq_status is restored by the silver_069 rollback below; until then the silver_070 version is a superset)
drop function if exists silver.refresh_scrape_context();
drop table if exists silver.fact_shelf_snapshot;
drop table if exists silver.fact_scrape_run;
drop table if exists silver.fact_serviceability;
drop table if exists silver.dim_sample_point;
drop table if exists silver.dim_listing;
drop table if exists silver.dim_catalog_product;
alter table silver.dim_product drop column if exists source_product_id;
delete from silver.sidnl_config where key = 'context_lookback_rows';

-- ==================================================================== 20261111063922 dash_011_coverage_collection
select cron.unschedule('sidnl-context');
drop function if exists dash.refresh_context();
drop table if exists dash.collection_health;
drop table if exists dash.coverage;
delete from dash.refresh_state where key = 'context_refreshed_at';

-- ==================================================================== 20261111064021 silver_071_essential_selftest
CREATE OR REPLACE FUNCTION silver.selftest_parser()
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare
    p silver.pack_t;
begin
    assert silver.norm_key('Mr. Munchies')   = 'mr munchies',  'norm_key dotted';
    assert silver.norm_key('MR.MUNCHIES')    = 'mr munchies',  'norm_key upper';
    assert silver.norm_key('Mr.Munchies')    = 'mr munchies',  'norm_key no space';
    assert silver.norm_key('Lay''s')         = 'lays',         'norm_key apostrophe';
    assert silver.norm_key('Crunch & Munch') = 'crunch and munch', 'norm_key ampersand';
    assert silver.norm_key('   ')            is null,          'norm_key blank';
    assert silver.norm_key(null)             is null,          'norm_key null';

    assert silver.brand_matches('mr munchies', 'Mr. Munchies'),     'brand exact';
    assert silver.brand_matches('mr munchies', 'MrMunchies'),       'brand compact';
    assert silver.brand_matches('mr munchies', 'mr-munchies'),      'brand hyphen';
    assert not silver.brand_matches('mr munchies', 'Crunch & Munch'), 'brand must not substring-match';
    assert not silver.brand_matches('mr munchies', 'Nestle Munch'),   'brand must not substring-match 2';
    assert not silver.brand_matches('mr munchies', null),             'brand null';

    p := silver.parse_pack('270 g');
    assert (p.size_value, p.size_unit, p.pack_count) = (270, 'g', 1), 'pack 270 g';
    p := silver.parse_pack('1 pc (38.5 g)');
    assert (p.size_value, p.size_unit, p.pack_count) = (38.5, 'g', 1), 'pack 1 pc (38.5 g)';
    p := silver.parse_pack('330 ml');
    assert (p.size_value, p.size_unit, p.pack_count) = (330, 'ml', 1), 'pack 330 ml';
    p := silver.parse_pack('1 L');
    assert (p.size_value, p.size_unit, p.pack_count) = (1000, 'ml', 1), 'pack 1 L -> 1000 ml';
    p := silver.parse_pack('1.5 Ltr');
    assert (p.size_value, p.size_unit, p.pack_count) = (1500, 'ml', 1), 'pack 1.5 Ltr';
    p := silver.parse_pack('2 kg');
    assert (p.size_value, p.size_unit, p.pack_count) = (2000, 'g', 1), 'pack 2 kg';
    p := silver.parse_pack('6 x 330 ml');
    assert (p.size_value, p.size_unit, p.pack_count) = (330, 'ml', 6), 'pack 6 x 330 ml';
    p := silver.parse_pack('0,5 kg');
    assert (p.size_value, p.size_unit, p.pack_count) = (500, 'g', 1), 'pack decimal comma';
    p := silver.parse_pack('1 N');
    assert (p.size_value, p.size_unit, p.pack_count) = (1, 'pc', 1), 'pack 1 N';
    p := silver.parse_pack('3 pcs');
    assert (p.size_value, p.size_unit, p.pack_count) = (3, 'pc', 1), 'pack 3 pcs = one pack of 3 pieces';
    p := silver.parse_pack(null);
    assert p.size_value is null and p.pack_count = 1, 'pack null';
    p := silver.parse_pack('assorted');
    assert p.size_value is null or p.size_unit = 'pc', 'pack junk does not crash';

    -- silver_056: exact pack strings seen in bronze public.platform_products
    p := silver.parse_pack('100 g X 2');
    assert (p.size_value, p.size_unit, p.pack_count) = (100, 'g', 2), 'pack 100 g X 2';
    p := silver.parse_pack('500 ml X 4');
    assert (p.size_value, p.size_unit, p.pack_count) = (500, 'ml', 4), 'pack 500 ml X 4';
    p := silver.parse_pack('2 x 1 pc');
    assert (p.size_value, p.size_unit, p.pack_count) = (1, 'pc', 2), 'pack 2 x 1 pc';
    p := silver.parse_pack('2 x 10 pcs');
    assert (p.size_value, p.size_unit, p.pack_count) = (10, 'pc', 2), 'pack 2 x 10 pcs';
    p := silver.parse_pack('10 pcs');
    assert (p.size_value, p.size_unit, p.pack_count) = (10, 'pc', 1), 'pack 10 pcs';
    p := silver.parse_pack('30 tabs');
    assert (p.size_value, p.size_unit, p.pack_count) = (30, 'pc', 1), 'pack 30 tabs';
    p := silver.parse_pack('60 capsules');
    assert (p.size_value, p.size_unit, p.pack_count) = (60, 'pc', 1), 'pack 60 capsules';
    p := silver.parse_pack('4 packs');
    assert (p.size_value, p.size_unit, p.pack_count) = (4, 'pc', 1), 'pack 4 packs';
    p := silver.parse_pack('1 unit + 1 unit');
    assert (p.size_value, p.size_unit, p.pack_count) = (1, 'pc', 2), 'pack 1 unit + 1 unit';
    p := silver.parse_pack('40U x 25g');
    assert (p.size_value, p.size_unit, p.pack_count) = (25, 'g', 40), 'pack 40U x 25g';
    p := silver.parse_pack('7 pcs + 102 g');
    assert (p.size_value, p.size_unit, p.pack_count) = (102, 'g', 1), 'pack 7 pcs + 102 g does not multiply';
    p := silver.parse_pack('1 pack (1.25 kg)');
    assert (p.size_value, p.size_unit, p.pack_count) = (1250, 'g', 1), 'pack 1 pack (1.25 kg)';
    p := silver.parse_pack('1 pack (5 X 10 ml)');
    assert (p.size_value, p.size_unit, p.pack_count) = (10, 'ml', 5), 'pack 1 pack (5 X 10 ml)';
    p := silver.parse_pack('2 x 45 g + 35 g');
    assert (p.size_value, p.size_unit, p.pack_count) = (125, 'g', 1), 'pack 2 x 45 g + 35 g';
    p := silver.parse_pack('100 g + 100 g');
    assert (p.size_value, p.size_unit, p.pack_count) = (100, 'g', 2), 'pack 100 g + 100 g';

    assert silver.parse_variant('Mr. Munchies Cheese Chilli Samosa (Frozen)', 'Mr. Munchies', 'Samosa') = 'Cheese Chilli', 'variant samosa';
    assert silver.parse_variant('Mr. Munchies Veg Spring Roll (Frozen)',      'Mr. Munchies', 'Spring Roll') = 'Veg', 'variant roll';
    assert silver.parse_variant('Mr. Munchies Spicy Frozen Paneer Bites',     'Mr. Munchies', 'Frozen Paneer Bites') = 'Spicy', 'variant paneer';
    assert silver.parse_variant('Mr. Munchies Lasooni Soya Chaap',            'Mr. Munchies', 'Soya Chaap') = 'Lasooni', 'variant chaap';
    assert silver.parse_variant('Mr. Munchies Samosa',                        'Mr. Munchies', 'Samosa') is null, 'variant empty -> null';

    assert silver.map_stock_status('in_stock')     = 'in_stock',     'state in';
    assert silver.map_stock_status('OUT_OF_STOCK') = 'out_of_stock', 'state out';
    assert silver.map_stock_status('not_listed')   = 'not_listed',   'state nl';
    assert silver.map_stock_status('weird')        = 'unknown',      'state unknown';
    assert silver.map_stock_status(null)           = 'unknown',      'state null';

    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',3,179,179)) = 'valid',   'dq clean';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'out_of_stock',0,null,null)) = 'valid', 'dq oos without price is valid';
    assert silver.dq_status(silver.reading_dq(true,false,now(),'in_stock',3,179,179)) = 'invalid', 'dq no store';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',-1,179,179)) = 'invalid', 'dq negative inv';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',3,200,179)) = 'suspect', 'dq sp > mrp';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',3,179,null)) = 'suspect', 'dq mrp missing';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'out_of_stock',4,179,179)) = 'suspect', 'dq oos with inventory';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',3,null,null)) = 'suspect', 'dq in stock no price';
    assert silver.dq_status(silver.reading_dq(true,true,now() + interval '30 days','in_stock',3,179,179)) = 'invalid', 'dq future ts';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'unknown',3,179,179)) = 'invalid', 'dq unknown state';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'not_listed',null,null,null)) = 'valid', 'dq not_listed valid';
    return 'all parser tests passed';
end
$function$
;

drop function if exists silver.selftest();
drop function if exists silver.selftest_pure();

-- ==================================================================== 20261111064053 silver_072_dq_gate_window
CREATE OR REPLACE FUNCTION silver.dq_checks(p_shelf_max bigint DEFAULT NULL::bigint)
 RETURNS TABLE(check_name text, severity text, scope text, violations bigint, total bigint, ok boolean, blocks boolean, detail text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
with pct as (select coalesce(silver.cfg('dq_reject_block_pct'), 5) as p),
lb  as (select coalesce(greatest(ps.last_seen_id - coalesce(silver.cfg('incremental_lookback_rows'), 5000)::bigint, 0), 0) as lo
          from silver.pipeline_source ps where ps.source_schema = 'public' and ps.source_table = 'shelf_positions'),
t as (
    select f.platform, f.l1_id, f.l2_id, count(*) as total,
           count(*) filter (where 'negative_price' = any (f.dq_flags))                       as neg,
           count(*) filter (where 'sp_gt_mrp'      = any (f.dq_flags))                       as sp,
           count(*) filter (where f.product_key is null and f.platform_product_id is not null) as unlinked,
           count(*) filter (where f.store_key is null)                                       as nostore,
           count(*) filter (where b.brand_key is null)                                       as nobrand
      from silver.fact_shelf_position f
      left join silver.dim_brand b on b.brand_key = f.brand_key
     group by 1, 2, 3),
m as (
    select sn.platform, sn.l1_id, sn.l2_id, count(*) as missing
      from public.shelf_positions sp
      join public.shelf_snapshots sn on sn.id = sp.snapshot_id
      join silver.category_scope cs on cs.platform = sn.platform and cs.l1_id = sn.l1_id
                                   and cs.l2_id = sn.l2_id and cs.is_enabled
      join silver.dim_platform dpl on dpl.platform = sn.platform and not dpl.is_test
      cross join lb
     where sn.status = 'ok' and sp.id > lb.lo
       and sp.id <= coalesce(p_shelf_max, (select max(id) from public.shelf_positions))
       and not exists (select 1 from silver.fact_shelf_position f where f.source_record_id = sp.id)
     group by 1, 2, 3),
per_scope as (
    select c.n, c.sev, t.platform || '/' || t.l1_id || '/' || t.l2_id as scope, c.v, t.total, coalesce(c.blk, false) as blk, c.d
      from t cross join pct
      cross join lateral (values
        ('shelf_negative_selling_price', 'rejected', t.neg,
            t.neg * 100.0 / nullif(t.total, 0) > pct.p,
            'rows rejected from valid analytical output (dq_status=invalid); scope blocked only above dq_reject_block_pct'),
        ('shelf_selling_price_above_mrp', 'warning', t.sp, false,
            'rows flagged suspect and excluded from price/discount metrics; never blocks'),
        ('shelf_row_without_product', 'blocking', t.unlinked, t.unlinked > 0,
            'referential integrity: shelf row has a platform_product_id but no dim_product link'),
        ('shelf_row_without_store', 'blocking', t.nostore, t.nostore > 0,
            'referential integrity: shelf row has no dim_store'),
        ('shelf_row_brand_not_in_dim_brand', 'blocking', t.nobrand, t.nobrand > 0,
            'referential integrity: brand_key missing in dim_brand')
      ) c (n, sev, v, blk, d)
    union all
    select 'shelf_bronze_rows_not_in_silver', 'blocking', m.platform || '/' || m.l1_id || '/' || m.l2_id,
           m.missing, t.total, m.missing > 0,
           'unprocessed bronze rows inside the processing window - watermark must not advance'
      from m left join t on t.platform = m.platform and t.l1_id = m.l1_id and t.l2_id = m.l2_id)
select n, sev, scope, v, total, false, blk, d from per_scope where v > 0
union all
select n, sev, 'all', coalesce(sum(v), 0), coalesce(sum(total), 0), coalesce(sum(v), 0) = 0, coalesce(bool_or(blk), false), min(d)
  from per_scope group by n, sev
union all
select 'dim_store_without_city_or_coords', 'accepted', 'dim_store',
       count(*) filter (where city_slug is null or latitude is null or longitude is null), count(*), true, false,
       'optional descriptive NULLs: kept NULL, not derivable from source'
  from silver.dim_store
union all
select 'dim_product_without_category', 'accepted', 'dim_product',
       count(*) filter (where category_key is null), count(*), true, false,
       'optional descriptive NULLs: kept NULL, not derivable from source'
  from silver.dim_product
union all
select 'canonical_empty_name_clean', 'accepted', 'canonical_product',
       count(*) filter (where coalesce(name_clean, '') = ''), count(*), true, false,
       'approved: unchanged, SI id and raw name preserved'
  from silver.canonical_product where is_active
union all
select 'canonical:' || q.check_name, 'blocking', 'canonical',
       case when q.ok then 0 else 1 end, 1, q.ok, not q.ok, q.detail
  from silver.quality_checks() q
$function$
;

drop index if exists silver.ix_fsp_unlinked;
drop index if exists silver.ix_fsp_no_store;
delete from silver.sidnl_config where key = 'dq_gate_window';

-- ==================================================================== 20261111070331 silver_073_inline_row_functions
alter function silver.reading_dq(boolean, boolean, timestamptz, text, integer, numeric, numeric) set search_path to 'silver', 'ops', 'public', 'pg_temp';
alter function silver.dq_status(text[]) set search_path to 'silver', 'ops', 'public', 'pg_temp';
alter function silver.map_stock_status(text) set search_path to 'silver', 'ops', 'public', 'pg_temp';
alter function silver.read_flags(text, boolean, boolean) set search_path to 'silver', 'pg_temp';
alter function silver.read_stock_status(text, text, boolean, boolean) set search_path to 'silver', 'pg_temp';
alter function silver.safe_int(text) set search_path to 'silver', 'pg_temp';

-- ==================================================================== 20261111104030 dash_012_ads_from_formula_sheet
-- UNDO THIS ONE FIRST (newer). Restores dash.ads to its pre-012 shape and the pre-012 dash.refresh_ads /
-- dash.v_sov_keyword. silver_074 must still be in place while this runs. The catalog rows ad_spend / kw_vol keep
-- their dash_012 text (their earlier text was not kept).
select cron.unschedule('sidnl-fp-ads');
drop trigger if exists fp_ads_refresh on public.fp_blinkit_ads;
drop function if exists silver.on_fp_ads_change();
drop function if exists silver.check_fp_ads();
delete from dash.metric_catalog where metric_key in ('ads_roas', 'ads_sales_atc_units', 'ads_impressions_cpm',
                                                     'ads_budget_claimables', 'sponsored_sov', 'ads_clicks_ctr_cpc_aov');
drop view if exists dash.v_sov_keyword;
drop table if exists dash.ads_keyword_sov;
drop table if exists dash.ads_campaign_period;
delete from dash.refresh_table_state where table_name in ('ads_campaign_period', 'ads_keyword_sov');
delete from dash.ads;
drop index if exists dash.ads_key;
alter table dash.ads drop column if exists report_level;
alter table dash.ads drop column if exists placement, drop column if exists subcampaign_id, drop column if exists match_type,
                     drop column if exists pacing_type, drop column if exists cpm_bid;
alter table dash.ads add column report_level text generated always as (
    case when keyword is not null then 'keyword' when sidnl_id is not null then 'sku' else 'campaign' end) stored;
create unique index ads_key on dash.ads (obs_date, platform, campaign_id, keyword, sidnl_id) nulls not distinct;
create view dash.v_sov_keyword as
select period_start, period_end, target_value as keyword, searches, sov_pct, loaded_at
  from silver.fact_fp_ads where report_type = 'sov_period' and dq_status = 'valid'
 order by period_end desc, sov_pct desc;
drop function if exists dash.refresh_formula_table(text);
-- pre-012 dash.refresh_ads (it double-counted recommendation days loaded from two files; restore only to undo)
CREATE OR REPLACE FUNCTION dash.refresh_ads()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'dash', 'silver', 'pg_temp'
AS $function$
declare
  v_rows bigint;
  v_t0   timestamptz := clock_timestamp();
begin
  delete from dash.ads;
  insert into dash.ads(obs_date, platform, campaign_id, keyword, sidnl_id,
    campaign_name, campaign_type, campaign_budget, ad_spend, impressions,
    direct_sales, indirect_sales, attributed_sales,
    direct_roas, total_roas, new_users_acquired,
    direct_atc, indirect_atc, atc,
    direct_qty_sold, indirect_qty_sold, total_qty_sold, most_viewed_position, cpm)
  select obs_date, 'blinkit', campaign_id, target_value, null,
    max(campaign_name), max(ad_type), max(total_budget), max(budget_consumed), max(impressions),
    max(direct_sales), max(indirect_sales), max(direct_sales) + max(indirect_sales),
    max(direct_roas), max(total_roas), max(new_users),
    max(direct_atc), max(indirect_atc), max(direct_atc) + max(indirect_atc),
    max(direct_qty), max(indirect_qty), max(direct_qty) + max(indirect_qty),
    max(most_viewed_position), max(cpm)
  from silver.fact_fp_ads
  where report_type = 'keyword_daily' and dq_status = 'valid'
  group by obs_date, campaign_id, target_value
  on conflict do nothing;
  insert into dash.ads(obs_date, platform, campaign_id, keyword, sidnl_id,
    campaign_name, campaign_type, campaign_budget, ad_spend, impressions,
    direct_sales, indirect_sales, attributed_sales,
    direct_roas, total_roas, new_users_acquired,
    direct_atc, indirect_atc, atc,
    direct_qty_sold, indirect_qty_sold, total_qty_sold, cpm)
  select obs_date, 'blinkit', campaign_id, null, null,
    max(campaign_name), 'Recommendation Ads', max(total_budget),
    sum(budget_consumed), sum(impressions),
    sum(direct_sales), sum(indirect_sales), sum(direct_sales) + sum(indirect_sales),
    case when sum(budget_consumed) > 0 then sum(direct_sales)/sum(budget_consumed) end,
    case when sum(budget_consumed) > 0
         then (sum(direct_sales)+sum(indirect_sales))/sum(budget_consumed) end,
    sum(new_users),
    sum(direct_atc), sum(indirect_atc), sum(direct_atc) + sum(indirect_atc),
    sum(direct_qty), sum(indirect_qty), sum(direct_qty) + sum(indirect_qty),
    max(cpm)
  from silver.fact_fp_ads
  where report_type = 'reco_daily' and dq_status = 'valid'
  group by obs_date, campaign_id
  on conflict do nothing;
  insert into dash.ads(obs_date, platform, campaign_id, keyword, sidnl_id,
    campaign_name, campaign_type, campaign_budget, impressions)
  select (select max(obs_date) from silver.fact_fp_ads where obs_date is not null),
         'blinkit', campaign_id, null, null,
    max(campaign_name), max(ad_type), max(total_budget), max(impressions)
  from silver.fact_fp_ads
  where report_type = 'mtd_claimables' and dq_status = 'valid'
  group by campaign_id
  on conflict do nothing;
  get diagnostics v_rows = row_count;
  insert into dash.refresh_table_state(table_name, last_refreshed_at, row_count, last_attempt_at, last_status)
  values ('ads', now(), (select count(*) from dash.ads), now(), 'success')
  on conflict (table_name) do update
    set last_refreshed_at = now(), row_count = (select count(*) from dash.ads),
        last_attempt_at = now(), last_status = 'success', last_error = null;
  return jsonb_build_object('status','success','rows', (select count(*) from dash.ads),
                            'ms', round(extract(epoch from clock_timestamp()-v_t0)*1000));
exception when others then
  insert into dash.refresh_table_state(table_name, last_attempt_at, last_status, last_error)
  values ('ads', now(), 'failed', sqlerrm)
  on conflict (table_name) do update
    set last_attempt_at = now(), last_status = 'failed', last_error = sqlerrm;
  return jsonb_build_object('status','failed','error', sqlerrm);
end $function$;

-- ==================================================================== 20261111103933 silver_074_fp_ads_formula_sheet
-- Undo after dash_012. Restores the insert-only loader that existed before (created outside the migration system),
-- removes the formula-sheet columns/rows, the grain table, the placement map and the silver views.
delete from silver.ref_metric_support where dash_table is not null and metric not in ('Ad spend', 'KW VOL (Monthly)');
update silver.ref_metric_support set support = 'not_available', silver_source = null, notes = 'No retail-media spend feed.'
 where pdf_section = 8 and metric = 'Ad spend';
update silver.ref_metric_support set support = 'not_available', silver_source = null,
       notes = 'Source metric from retail-media platform; not scraped.'
 where pdf_section = 8 and metric = 'KW VOL (Monthly)';
drop index if exists silver.ref_metric_support_dash_column;
alter table silver.ref_metric_support drop column if exists dash_table, drop column if exists dash_column,
                                      drop column if exists sql_expr, drop column if exists grain_levels;
drop table if exists silver.ref_dash_grain;
drop view if exists silver.v_fp_ads_keyword_period;
drop view if exists silver.v_fp_ads_campaign_period;
drop view if exists silver.v_fp_ads_keyword_daily;
drop view if exists silver.v_fp_ads_daily;
drop table if exists silver.ref_ad_placement;
CREATE OR REPLACE FUNCTION silver.load_fp_ads()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'public', 'pg_temp'
AS $function$
declare
  v_rows bigint;
begin
  insert into silver.fact_fp_ads(fp_ads_id, report_type, obs_date, period_start, period_end,
    campaign_id, campaign_name, subcampaign_id, ad_type, target_type, target_value,
    match_type, most_viewed_position, cpm, total_budget, impressions,
    direct_atc, indirect_atc, new_users, direct_sales, indirect_sales,
    direct_qty, indirect_qty, budget_consumed, direct_roas, total_roas,
    searches, sov_pct, claimables, served_budget, loaded_at)
  select id, report_type, obs_date, period_start, period_end,
    campaign_id, campaign_name, subcampaign_id, ad_type, target_type, target_value,
    match_type, most_viewed_position, cpm, total_budget, impressions,
    direct_atc, indirect_atc, new_users, direct_sales, indirect_sales,
    direct_qty, indirect_qty, budget_consumed, direct_roas, total_roas,
    searches, sov_pct, claimables, served_budget, loaded_at
  from public.fp_blinkit_ads b
  where not exists (select 1 from silver.fact_fp_ads s where s.fp_ads_id = b.id)
  on conflict (fp_ads_id) do nothing;
  get diagnostics v_rows = row_count;
  update silver.fact_fp_ads
     set dq_status = 'suspect'
   where dq_status = 'valid'
     and (direct_sales < 0 or indirect_sales < 0 or budget_consumed < 0
          or direct_roas < 0 or total_roas < 0);
  return jsonb_build_object('status','ok','new_silver_rows', v_rows,
                            'total', (select count(*) from silver.fact_fp_ads));
end $function$;
alter table silver.fact_fp_ads drop column if exists platform, drop column if exists source_file,
                               drop column if exists pacing_type, drop column if exists placement,
                               drop column if exists dq_flags;

-- ==================================================================== 20261113062816 silver_075_platform_listings_brand_drift
-- Puts back the original text of silver.refresh_brand (it reads platform_listings.brand, a column the scraper
-- schema no longer has, so the discover stage and refresh_brand fail again: only do this if the column returns).
do $rb$
declare v_def text;
begin
    v_def := pg_get_functiondef('silver.refresh_brand(text,boolean)'::regprocedure);
    execute replace(v_def, 'coalesce(to_jsonb(pl) ->> ''brand'', p.brand)', 'coalesce(pl.brand, p.brand)');
end
$rb$;
create or replace function silver.refresh_brand_strings(p_full boolean default false)
 returns integer
 language plpgsql
 set search_path to 'silver', 'ops', 'public', 'pg_temp'
as $function$
declare v_n int := 0; v_c int;
begin
    insert into silver.brand_string_registry (raw_brand)
    select distinct brand::text from public.platform_products where brand is not null
    on conflict do nothing;
    get diagnostics v_c = row_count; v_n := v_n + v_c;

    insert into silver.brand_string_registry (raw_brand)
    select distinct brand::text from public.platform_listings where brand is not null
    on conflict do nothing;
    get diagnostics v_c = row_count; v_n := v_n + v_c;

    insert into silver.brand_string_registry (raw_brand)
    select distinct brand::text from public.products where brand is not null
    on conflict do nothing;
    get diagnostics v_c = row_count;
    return v_n + v_c;
end $function$;

-- ==================================================================== 20261113062951 dash_013_competitors
-- Purely additive objects (two tables, one function, two views, one cron job). No bronze/silver data is touched.
do $rb$
begin
    if exists (select 1 from cron.job where jobname = 'sidnl-competitors') then
        perform cron.unschedule('sidnl-competitors');
    end if;
end
$rb$;
drop view if exists dash.v_comp_cross_marketplace;
drop view if exists dash.v_comp_price_gap;
drop function if exists dash.refresh_competitors();
drop table if exists dash.comp_brand_day;
drop table if exists dash.comp_sku_day;
delete from dash.refresh_table_state where table_name in ('comp_sku_day', 'comp_brand_day');

-- ==================================================================== 20261113065733 silver_076_refresh_brand_listing_columns
-- Puts back the original _listings select of silver.refresh_brand (it reads platform_listings.name / pack_size /
-- image_url, columns the scraper schema no longer has, so refresh_brand fails again: only do this if they return).
do $rb$
declare v_def text;
begin
    v_def := pg_get_functiondef('silver.refresh_brand(text,boolean)'::regprocedure);
    v_def := replace(v_def, E'\n    left join public.platform_products pp on pp.platform = pl.platform and pp.external_id = pl.external_id', '');
    v_def := replace(v_def, 'pp.image_url     as image_url,', 'coalesce(pl.image_url, p.image_url)     as image_url,');
    v_def := replace(v_def, 'pp.pack                                 as pack_size,', 'pl.pack_size,');
    v_def := replace(v_def, 'coalesce(pp.name, p.name)', 'coalesce(pl.name, p.name)');
    execute v_def;
end
$rb$;

-- ==================================================================== 20261113065746 dash_014_competitors_cron_reregister
-- Removes the cron job (dash_013's rollback does the same). The tables and refresh function stay; refresh by hand with
-- select dash.refresh_competitors();
do $rb$
begin
    if exists (select 1 from cron.job where jobname = 'sidnl-competitors') then
        perform cron.unschedule('sidnl-competitors');
    end if;
end
$rb$;

-- ==================================================================== 20261113071412 dash_015_sidnl_id_mapping
-- Back to a stored comp_sku_day.sidnl_id (filled from product_xref now, stale again after the next renumbering), the dash_013
-- refresh function text, the cross-marketplace view on the table, and dash.v_valid_reading without sidnl_id.
-- Removes dash.v_comp_sku_day, dash.v_cfg_sku and the comment on dash.ads.sidnl_id.
drop view if exists dash.v_cfg_sku;
drop view if exists dash.v_comp_cross_marketplace;
drop view if exists dash.v_comp_sku_day;
alter table dash.comp_sku_day add column if not exists sidnl_id text;
update dash.comp_sku_day c set sidnl_id = x.sidnl_id from silver.product_xref x where x.product_key = c.product_key;
create index if not exists comp_sku_day_sidnl_idx on dash.comp_sku_day (sidnl_id, city_slug) where sidnl_id is not null;
do $rb$
declare v_def text;
begin
    v_def := pg_get_functiondef('dash.refresh_competitors()'::regprocedure);
    v_def := replace(v_def, 'product_key, brand_key, brand_name,', 'product_key, sidnl_id, brand_key, brand_name,');
    v_def := replace(v_def, 'dp.total_content,', 'dp.total_content, x.sidnl_id,');
    v_def := replace(v_def, 'left join silver.dim_brand db on db.brand_key = dp.brand_key',
                     E'left join silver.dim_brand db on db.brand_key = dp.brand_key\n              left join silver.product_xref x on x.product_key = a.product_key');
    execute v_def;
end
$rb$;
create view dash.v_comp_cross_marketplace as
with latest as (
    select distinct on (platform, city_slug, sidnl_id)
           platform, city_slug, sidnl_id, brand_key, brand_name, product_name, pack_raw, obs_date,
           sp_median, mrp_median, price_per_100, price_unit
      from dash.comp_sku_day
     where sidnl_id is not null and sp_median is not null
     order by platform, city_slug, sidnl_id, obs_date desc),
multi as (select city_slug, sidnl_id from latest group by 1, 2 having count(distinct platform) >= 2)
select l.sidnl_id, l.city_slug, max(l.brand_name) as brand_name, max(l.product_name) as product_name,
       max(l.pack_raw) as pack_raw,
       min(l.sp_median) as min_sp, max(l.sp_median) as max_sp,
       max(l.sp_median) - min(l.sp_median) as price_gap,
       round(100 * (max(l.sp_median) - min(l.sp_median)) / nullif(min(l.sp_median), 0), 2) as price_gap_pct,
       (array_agg(l.platform order by l.sp_median asc,  l.platform))[1] as cheapest_platform,
       (array_agg(l.platform order by l.sp_median desc, l.platform))[1] as dearest_platform,
       jsonb_object_agg(l.platform, l.sp_median) as sp_by_platform,
       jsonb_object_agg(l.platform, l.obs_date)  as obs_date_by_platform
  from latest l join multi m using (city_slug, sidnl_id)
 group by l.sidnl_id, l.city_slug;
alter view dash.v_comp_price_gap reset (security_invoker);
drop view if exists dash.v_valid_reading;
create view dash.v_valid_reading with (security_invoker = true) as
select r.reading_key, r.source_type, r.source_record_id, r.job_ref, r.observed_at, r.obs_date, r.platform, r.brand_key,
       r.brand_name, r.company_name, r.product_key, r.platform_product_id, r.product_name, r.variant, r.product_type,
       r.pack_raw, r.size_value, r.size_unit, r.pack_count, r.l1_id, r.l1_category, r.l2_id, r.l2_category, r.l3_id,
       r.l3_category, r.category_path, r.store_key, r.source_store_id, r.store_external_id, r.store_name, r.city_slug,
       r.city_name, r.state, r.latitude, r.longitude, r.stock_status, r.is_listed, r.is_available, r.inventory_units,
       r.inventory_is_capped, r.selling_price, r.mrp, r.discount_amount, r.discount_pct, r.search_position,
       r.organic_position, r.is_ad, r.ad_type, r.osa_eligible, r.dq_status, r.dq_flags, r.age_hours, r.freshness
  from silver.v_reading r
  join silver.dim_platform dp on dp.platform = r.platform and not dp.is_test
 where r.dq_status = 'valid';
comment on view dash.v_valid_reading is
    'silver.v_reading limited to dq_status=valid and non-test platforms. Single entry point for all gold metrics.';
comment on table dash.comp_sku_day is
    'Competitor layer: one SKU x city x day from category-shelf scrapes (all brands that share a shelf with a client brand). sp_median = median over the stores that listed it; osa_pct = in_stock_obs / valid_obs.';
comment on column dash.ads.sidnl_id is null;

-- dash_016_fp_metric_views rollback: drops the metric views and puts the fp_* tables back to RLS-off (data is kept).
drop view if exists dash.v_fp_ad_wallet_day, dash.v_fp_ad_page, dash.v_fp_finance_summary, dash.v_fp_debit_note_month,
  dash.v_fp_invoice_recon, dash.v_fp_po_month, dash.v_fp_po_status, dash.v_fp_po_sku, dash.v_fp_po_summary,
  dash.v_fp_po_line_all, dash.v_fp_sales_sku, dash.v_fp_sku_cost, dash.v_fp_sku_stock, dash.v_fp_sales_city,
  dash.v_fp_sales_health, dash.v_fp_sales_month, dash.v_fp_sales_day;
do $$ declare t text; begin
  foreach t in array array['fp_sku','fp_sku_name','fp_sales_daily','fp_po','fp_po_line','fp_grn_line','fp_ad_wallet_txn',
    'fp_ad_page_perf','fp_fill_rate','fp_new_user_share','fp_invoice','fp_payment_advice','fp_debit_credit_note',
    'fp_ledger_entry','fp_product_snapshot','fp_load_log'] loop
    execute format('alter table dash.%I disable row level security', t);
  end loop; end $$;

-- dash_017_refresh_state_brand_default rollback (brand_id stays NOT NULL; the three refresh writers will fail again until they pass brand_id)
alter table dash.refresh_table_state alter column brand_id drop default;
