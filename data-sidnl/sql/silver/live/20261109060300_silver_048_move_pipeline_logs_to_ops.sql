-- Silver keeps only what metrics need. Pipeline run history, data-quality results and monitoring move to schema ops.
-- Function bodies are rewritten to the new names. Public is untouched.
do $$
declare
  t text; v text; f record; d text; rx text; cfg text;
  tabs text[] := array['dq_result','etl_run','pipeline_run','pipeline_job','storage_snapshot','storage_alert_log','cron_alert_log','function_backup'];
  vws  text[] := array['v_pipeline_status','v_silver_health','v_job_history','v_dq_latest','v_dq_summary','v_storage_monitor','v_storage_projection','v_cron_health','v_quality_latest'];
begin
  perform pg_advisory_xact_lock(727100);
  perform pg_advisory_xact_lock(727101);

  create schema if not exists ops;
  comment on schema ops is 'Pipeline run history, data-quality results and monitoring. Not metric data; silver holds only what metrics need.';

  foreach t in array tabs loop
    execute format('alter table silver.%I set schema ops', t);
    execute format('alter table ops.%I enable row level security', t);
  end loop;
  foreach v in array vws loop
    execute format('alter view silver.%I set schema ops', v);
  end loop;
  revoke all on schema ops from anon, authenticated;
  revoke all on all tables in schema ops from anon, authenticated;

  rx := 'silver\.(' || array_to_string(tabs || vws, '|') || ')\y';

  for f in
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('silver','gold','public') and p.prokind = 'f' and p.prosrc ~ rx
  loop
    d := regexp_replace(pg_get_functiondef(f.oid), rx, 'ops.\1', 'g');
    execute d;
  end loop;

  for f in
    select p.oid::regprocedure::text as sig, c as cfgline
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace, unnest(p.proconfig) c
     where n.nspname = 'silver' and p.prokind = 'f' and c like 'search_path=%' and c not like '%ops%'
  loop
    cfg := regexp_replace(f.cfgline, '^search_path=', '');
    cfg := regexp_replace(cfg, '^("?silver"?),? ?', '\1, ops, ');
    execute format('alter function %s set search_path = %s', f.sig, cfg);
  end loop;
end $$;
