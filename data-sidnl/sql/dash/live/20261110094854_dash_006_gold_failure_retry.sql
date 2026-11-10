-- dash_006_gold_failure_retry
-- Gap 1 of docs/fallbacks-design.md.
-- A failed dash.refresh (or dash.sync_dims) now marks the gold run 'failed' and is retried with the Silver backoff
-- rules (transient vs permanent, silver.backoff_minutes, max attempts from config). A statement timeout is caught
-- explicitly (PL/pgSQL "when others" does not catch query_canceled). Previous dash.* rows stay served because the
-- whole sync+refresh runs in one savepoint that is rolled back on error.
-- Additive: one new table, one new view, two config rows; silver.run_gold_pending() replaced with the same
-- signature and return shape (old text saved in ops.function_backup, tag pre_dash_006).

insert into ops.function_backup (fn, tag, definition)
select 'silver.run_gold_pending()', 'pre_dash_006', pg_get_functiondef('silver.run_gold_pending()'::regprocedure);

insert into silver.sidnl_config (key, value_num, description) values
  ('gold_max_attempts', 5, 'Gold (dash) refresh: a transient failure is retried until this many attempts; permanent errors are never retried')
on conflict (key) do nothing;

insert into dash.cfg_threshold (key, value, description) values
  ('gold_stale_minutes', 180, 'dash.v_refresh_status: a table counts as stale when its last successful refresh is older than this many minutes')
on conflict (key) do nothing;

create table dash.refresh_table_state (
    table_name          text primary key,
    last_refreshed_at   timestamptz,
    last_run_id         bigint,
    row_count           bigint,
    last_attempt_at     timestamptz,
    last_attempt_run_id bigint,
    last_status         text check (last_status in ('success', 'failed')),
    last_error          text,
    gold_attempts       integer not null default 0,
    next_retry_at       timestamptz
);
alter table dash.refresh_table_state enable row level security;
comment on table dash.refresh_table_state is
  'One row per dash table rewritten by silver.run_gold_pending(). last_refreshed_at moves only on success; failures set last_attempt_at/last_status/last_error.';

create or replace function silver.run_gold_pending()
 returns jsonb
 language plpgsql
 set search_path to 'silver', 'ops', 'public', 'pg_temp'
 set statement_timeout to '600s'
as $function$
declare
    v record; v_t timestamptz; v_att int; v_state text; v_msg text; v_class text; v_next timestamptz; v_secs numeric;
    v_max int := coalesce(silver.cfg('gold_max_attempts'), 5)::int;
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
        perform dash.refresh(3);
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
    return jsonb_build_object('status', 'success', 'run_id', v.run_id, 'dash', 'success');
end $function$;

create view dash.v_refresh_status with (security_invoker = true) as
select s.table_name,
       s.last_refreshed_at,
       round(extract(epoch from now() - s.last_refreshed_at) / 60, 1) as age_minutes,
       s.row_count,
       s.last_status,
       s.last_attempt_at,
       s.last_error,
       s.gold_attempts,
       s.next_retry_at,
       (s.last_status = 'failed') as refresh_failing,
       (s.last_status = 'failed' and s.next_retry_at is null) as needs_attention,
       (s.last_refreshed_at is null
        or now() - s.last_refreshed_at > make_interval(mins => coalesce(
               (select c.value from dash.cfg_threshold c where c.key = 'gold_stale_minutes'), 180)::int)) as is_stale
from dash.refresh_table_state s;
comment on view dash.v_refresh_status is
  'App "last refreshed" badge: one row per dash table. is_stale = last success older than cfg_threshold.gold_stale_minutes. refresh_failing = latest attempt failed (old data still served). needs_attention = failed and no retry scheduled (permanent error or attempts exhausted).';
