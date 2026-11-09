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
