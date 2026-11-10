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
