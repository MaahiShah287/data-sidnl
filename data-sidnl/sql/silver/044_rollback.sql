-- restore 042 record_storage_snapshot, 043 view definition; drop additive 044 objects
create or replace function silver.record_storage_snapshot() returns integer
language plpgsql set search_path to 'silver','public','pg_temp' as $f$
declare v_d date := (now() at time zone 'Asia/Kolkata')::date; v_n int := 0;
begin
  begin perform silver.check_storage_alert(); exception when others then raise warning 'check_storage_alert failed: %', sqlerrm; end;
  if exists (select 1 from silver.storage_snapshot where snapshot_date = v_d) then return 0; end if;
  insert into silver.storage_snapshot (snapshot_date, relation, total_bytes, table_bytes, index_bytes, live_rows, dead_rows, db_bytes)
  select v_d, n.nspname || '.' || c.relname, pg_total_relation_size(c.oid), pg_relation_size(c.oid), pg_indexes_size(c.oid),
         s.n_live_tup, s.n_dead_tup, pg_database_size(current_database())
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    left join pg_stat_all_tables s on s.relid = c.oid
   where c.relkind = 'r' and n.nspname in ('silver','public') and pg_total_relation_size(c.oid) > 1024*1024
  on conflict do nothing;
  get diagnostics v_n = row_count; return v_n;
end $f$;
drop function if exists silver.check_cron_alert();
drop table if exists silver.cron_alert_log;
delete from silver.sidnl_config where key = 'cron_alert_consecutive_failures';
create or replace view silver.v_cron_health with (security_invoker = true) as
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
