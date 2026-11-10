-- dash_007_visibility_full_rebuild
-- dash.visibility is stored by sidnl_id, but SI ids are renumbered A-Z by the pipeline (36 of the last 54 runs,
-- up to 7,108 ids in one run). run_gold_pending called dash.refresh(3), which rebuilds only the last 3 days of
-- visibility, so older days kept SI ids from before the renumbering: on 2026-11-10, 10,427 of 11,069 category rows
-- for 10-29 / 10-31 / 11-04 (~560k impressions) were credited to the wrong products, and 11-06 was missing.
-- Fix: the visibility window comes from config key gold_visibility_days; NULL (the default, and the value set here)
-- rebuilds every date, which stays correct after any mapping change (renumber, merge, review, parser fix).
-- Measured on live data: full refresh 39.5 s vs 30.7 s for 3 days.
-- Also re-queues the latest successful run for gold so the wrong rows are rebuilt within a minute by sidnl-gold.

insert into ops.function_backup (fn, tag, definition)
select 'silver.run_gold_pending()', 'pre_dash_007', pg_get_functiondef('silver.run_gold_pending()'::regprocedure);

insert into silver.sidnl_config (key, value_num, description) values
  ('gold_visibility_days', null, 'Days of dash.visibility rebuilt per gold refresh. NULL = all dates (required: visibility is keyed by sidnl_id and SI ids are renumbered A-Z)')
on conflict (key) do nothing;

create or replace function silver.run_gold_pending()
 returns jsonb
 language plpgsql
 set search_path to 'silver', 'ops', 'public', 'pg_temp'
 set statement_timeout to '600s'
as $function$
declare
    v record; v_t timestamptz; v_att int; v_state text; v_msg text; v_class text; v_next timestamptz; v_secs numeric;
    v_max int := coalesce(silver.cfg('gold_max_attempts'), 5)::int;
    v_vis_days int := silver.cfg('gold_visibility_days')::int;
    v_tables text[] := array['dim_platform', 'dim_city', 'dim_brand', 'dim_category', 'dim_product', 'dim_store', 'dim_sidnl',
                             'pricing', 'availability', 'visibility'];
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
        perform dash.refresh(v_vis_days);
    exception
        when query_canceled then
            v_state := sqlstate; v_msg := 'timeout: ' || sqlerrm;
        when others then
            v_state := sqlstate; v_msg := sqlerrm;
    end;
    v_secs := round(extract(epoch from clock_timestamp() - v_t)::numeric, 2);

    if v_state is not null then
        v_att   := coalesce(v.gold_attempts, 0) + 1;
        v_class := silver.classify_error(v_state);
        v_next  := case when v_class = 'transient' and v_att < v_max
                        then now() + make_interval(mins => silver.backoff_minutes(v_att)) end;
        update ops.pipeline_run
           set gold_status = 'failed', gold_error = left(v_msg, 1000), gold_attempts = v_att,
               gold_seconds = v_secs, gold_next_at = v_next
         where run_id = v.run_id;
        insert into dash.refresh_state (key, value) values ('last_error', left(v_msg, 1000))
        on conflict (key) do update set value = excluded.value, updated_at = now();
        insert into dash.refresh_table_state (table_name, last_attempt_at, last_attempt_run_id, last_status, last_error, gold_attempts, next_retry_at)
        select t, now(), v.run_id, 'failed', left(v_msg, 1000), v_att, v_next from unnest(v_tables) t
        on conflict (table_name) do update
           set last_attempt_at = excluded.last_attempt_at, last_attempt_run_id = excluded.last_attempt_run_id,
               last_status = 'failed', last_error = excluded.last_error,
               gold_attempts = excluded.gold_attempts, next_retry_at = excluded.next_retry_at;
        return jsonb_build_object('status', 'failed', 'run_id', v.run_id, 'error', v_msg, 'sqlstate', v_state,
                                  'error_class', v_class, 'attempt', v_att, 'next_attempt_at', v_next);
    end if;

    delete from dash.refresh_state where key = 'last_error';
    update ops.pipeline_run set gold_status = 'success', gold_error = null, gold_next_at = null, gold_seconds = v_secs
     where run_id = v.run_id;
    insert into dash.refresh_table_state (table_name, last_refreshed_at, last_run_id, row_count, last_attempt_at,
                                          last_attempt_run_id, last_status, last_error, gold_attempts, next_retry_at)
    select c.t, now(), v.run_id, c.n, now(), v.run_id, 'success', null, 0, null
      from (values ('dim_platform', (select count(*) from dash.dim_platform)),
                   ('dim_city',     (select count(*) from dash.dim_city)),
                   ('dim_brand',    (select count(*) from dash.dim_brand)),
                   ('dim_category', (select count(*) from dash.dim_category)),
                   ('dim_product',  (select count(*) from dash.dim_product)),
                   ('dim_store',    (select count(*) from dash.dim_store)),
                   ('dim_sidnl',    (select count(*) from dash.dim_sidnl)),
                   ('pricing',      (select count(*) from dash.pricing)),
                   ('availability', (select count(*) from dash.availability)),
                   ('visibility',   (select count(*) from dash.visibility))) c(t, n)
    on conflict (table_name) do update
       set last_refreshed_at = excluded.last_refreshed_at, last_run_id = excluded.last_run_id, row_count = excluded.row_count,
           last_attempt_at = excluded.last_attempt_at, last_attempt_run_id = excluded.last_attempt_run_id,
           last_status = 'success', last_error = null, gold_attempts = 0, next_retry_at = null;
    return jsonb_build_object('status', 'success', 'run_id', v.run_id, 'dash', 'success', 'visibility_days', v_vis_days);
end $function$;

update ops.pipeline_run set gold_status = 'pending'
 where run_id = (select max(run_id) from ops.pipeline_run where status = 'success');
