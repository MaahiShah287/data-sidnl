-- =============================================================================
-- File:    20261110124500_silver_064_heartbeat.sql
-- Gap:     5 (fallbacks-design.md) — cron-dead detection + lock-safe daily job
-- Status:  IMPLEMENTS GAP 5 (SQL part). Q2 decision: cron-timing behaviour
--          accepted as "not tested" (no Supabase branch). Q6: YES to replacing
--          the sidnl-pipeline-daily cron command (step 3, admin).
-- External: edge function 'heartbeat' (edge-functions/heartbeat/index.ts) +
--           an uptime monitor polling it every 5 min (UptimeRobot etc.).
-- Rollback: 064_rollback.sql
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Config
-- ---------------------------------------------------------------------------
insert into silver.sidnl_config(key, value_num, description) values
  ('heartbeat_pipeline_max_minutes', 10, 'max age of last cron run start for sidnl-pipeline'),
  ('heartbeat_gold_max_minutes',     10, 'max age of last cron run start for sidnl-gold'),
  ('heartbeat_daily_max_hours',      26, 'max age of last daily enqueue'),
  ('heartbeat_run_max_minutes',      30, 'idle OK, but bronze advanced without a run starting within this = overdue')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Heartbeat view (read-only; no secrets, no sensitive data)
-- ---------------------------------------------------------------------------
create or replace view ops.v_heartbeat
with (security_invoker = true) as
-- pg_cron jobs themselves
select j.jobname,
       j.active,
       (select max(start_time) from cron.job_run_details r
         where r.jobid = j.jobid) as last_start,
       (select status from cron.job_run_details r
         where r.jobid = j.jobid order by start_time desc limit 1) as last_status,
       case j.jobname
         when 'sidnl-pipeline' then now() - make_interval(mins => silver.cfg('heartbeat_pipeline_max_minutes'))
         when 'sidnl-gold'     then now() - make_interval(mins => silver.cfg('heartbeat_gold_max_minutes'))
         when 'sidnl-pipeline-daily' then now() - make_interval(hours => silver.cfg('heartbeat_daily_max_hours'))
       end as expected_by
from cron.job j
where j.jobname like 'sidnl-%'

union all

-- pipeline itself is allowed to be idle, but bronze must not advance silently
select 'pipeline-run-progress',
       true,
       (select max(started_at) from ops.pipeline_run),
       null,
       now() - make_interval(mins => silver.cfg('heartbeat_run_max_minutes'));

-- ---------------------------------------------------------------------------
-- 3. Lock-safe daily enqueue (fixes the recurring 18:35 timeout, §0.4 #5)
-- ---------------------------------------------------------------------------
create or replace function silver.enqueue_daily_safe(p_reason text)
returns bigint
language plpgsql security definer as $$
begin
  return silver.enqueue_daily(p_reason, false);
exception
  when unique_violation or lock_not_available then
    -- daily job already queued by an in-flight catch-up tick: not an error
    return null;
end $$;

-- ---------------------------------------------------------------------------
-- 4. ADMIN STEP (Q6 approved — run in Supabase SQL editor):
--    select cron.unschedule('sidnl-pipeline-daily');
--    select cron.schedule('sidnl-pipeline-daily', '35 18 * * *', $$
--      set lock_timeout='5s';
--      select silver.enqueue_daily_safe('cron-daily');
--    $$);
-- ---------------------------------------------------------------------------
