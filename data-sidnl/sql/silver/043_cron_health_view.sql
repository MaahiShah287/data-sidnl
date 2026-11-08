-- 043: visibility for failures PL/pgSQL cannot catch (statement_timeout 57014 / cancel aborts the whole cron call;
-- the transaction rolls back, watermarks do not move, the next tick retries, but nothing is written to pipeline_job).
-- Additive, read-only view. No change to any function, job or data.
create or replace view silver.v_cron_health with (security_invoker = true) as
select j.jobname,
       j.schedule,
       j.active,
       count(d.runid) filter (where d.start_time > now() - interval '24 hours')                              as runs_24h,
       count(d.runid) filter (where d.start_time > now() - interval '24 hours' and d.status = 'failed')      as failures_24h,
       max(d.start_time) filter (where d.status = 'succeeded')                                                as last_success_at,
       max(d.start_time) filter (where d.status = 'failed')                                                   as last_failure_at,
       (select x.return_message from cron.job_run_details x
         where x.jobid = j.jobid and x.status = 'failed' order by x.start_time desc limit 1)                  as last_failure_message,
       (select count(*) from cron.job_run_details x
         where x.jobid = j.jobid
           and x.start_time > coalesce((select max(y.start_time) from cron.job_run_details y
                                         where y.jobid = j.jobid and y.status = 'succeeded'), '-infinity'))   as consecutive_failures
from cron.job j
left join cron.job_run_details d on d.jobid = j.jobid and d.start_time > now() - interval '7 days'
where j.jobname like 'sidnl-%'
group by j.jobid, j.jobname, j.schedule, j.active;
comment on view silver.v_cron_health is 'Per-cron-job health for sidnl-* jobs incl. failures that bypass silver.pipeline_job (statement timeouts).';
