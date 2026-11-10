-- =============================================================================
-- Pending Migrations for SIDNL: silver_064_heartbeat & silver_065_alert_outbox
-- Apply via Supabase SQL Editor or Supabase CLI (apply_migration).
--
-- WORKFLOW:
-- 1. Dry run each migration in a rolled-back transaction (see dry run comments).
-- 2. Apply migration to production.
-- 3. Verify: md5 check against supabase_migrations.schema_migrations.
-- 4. Regenerate schema baseline: python sidnl.py export-schema
-- 5. Verify repo matches live: python sidnl.py verify
-- 6. Commit and push.
-- =============================================================================


-- =============================================================================
-- SECTION 1: silver_064_heartbeat
-- Gap 5: cron-dead detection (ops.v_heartbeat) + lock-safe daily job
-- Rollback: sql/rollbacks.sql §silver_064
-- =============================================================================

-- 1. Config
insert into silver.sidnl_config(key, value_num, description) values
  ('heartbeat_pipeline_max_minutes', 10, 'max age of last cron run start for sidnl-pipeline before heartbeat is overdue'),
  ('heartbeat_gold_max_minutes',     10, 'max age of last cron run start for sidnl-gold before heartbeat is overdue'),
  ('heartbeat_daily_max_hours',      26, 'max age of last daily enqueue before heartbeat is overdue')
on conflict (key) do nothing;

-- 2. Heartbeat view (read-only; exposes only job names, ages, ok/overdue)
create or replace view ops.v_heartbeat
with (security_invoker = true) as
select
    j.jobname,
    j.active,
    (select max(r.start_time) from cron.job_run_details r
      where r.jobid = j.jobid)                                              as last_start,
    (select r.status from cron.job_run_details r
      where r.jobid = j.jobid order by r.start_time desc limit 1)           as last_status,
    case
        when j.jobname = 'sidnl-pipeline' then
            now() - make_interval(mins => coalesce(silver.cfg('heartbeat_pipeline_max_minutes'), 10))
        when j.jobname = 'sidnl-gold' then
            now() - make_interval(mins => coalesce(silver.cfg('heartbeat_gold_max_minutes'), 10))
        when j.schedule in ('35 18 * * *', '5 19 * * *', '20 19 * * *', '40 19 * * *') then
            now() - make_interval(hours => coalesce(silver.cfg('heartbeat_daily_max_hours'), 26))
        when j.schedule = '* * * * *' then now() - interval '10 minutes'
        when j.schedule = '*/5 * * * *' then now() - interval '15 minutes'
        when j.schedule = '*/10 * * * *' then now() - interval '20 minutes'
        when j.schedule = '*/15 * * * *' then now() - interval '45 minutes'
        else now() - interval '25 hours'
    end                                                                     as expected_by
from cron.job j
where j.jobname like 'sidnl-%'
;

comment on view ops.v_heartbeat is
  'One row per sidnl-* cron job. Per-schedule expected_by detects overdue jobs; '
  'the heartbeat edge function also reports paused jobs and the latest failed run. '
  'Polled by the heartbeat edge function every 5 min; returns 200 (all ok) or 503 (any overdue).';

-- 3. Lock-safe daily enqueue (prevents 18:35 timeout when run_tick holds the advisory lock)
create or replace function silver.enqueue_daily_safe(p_reason text)
returns bigint
language plpgsql
security definer
set search_path = silver, ops, public, pg_temp
as $$
begin
    return silver.enqueue_daily(p_reason, false);
exception
    when unique_violation or lock_not_available then
        return null;
end $$;

comment on function silver.enqueue_daily_safe(text) is
  'Wrapper around silver.enqueue_daily that swallows unique_violation / lock_not_available '
  'so the 18:35 cron job does not time out when run_tick holds the same daily-job row.';


-- =============================================================================
-- SECTION 2: silver_065_alert_outbox
-- Gap 4: alert delivery: ops.alert_outbox + triggers + claim/mark API
-- Rollback: sql/rollbacks.sql §silver_065
-- =============================================================================

-- 1. Config (disabled by default — flip to 1 after edge function is live)
insert into silver.sidnl_config(key, value_num, description) values
  ('alert_delivery_enabled',        0, '1 = edge function may deliver outbox rows; 0 = collect only'),
  ('alert_max_attempts',            6, 'delivery attempts before an alert row is marked dead'),
  ('alert_claim_timeout_minutes',   5, 'rows stuck in sending longer than this are reclaimed as failed (at-most-once)')
on conflict (key) do nothing;

-- 2. Outbox table
create table if not exists ops.alert_outbox (
    alert_id        bigint generated always as identity primary key,
    dedupe_key      text        unique not null,
    source          text        not null
                                check (source in ('cron', 'storage', 'freshness', 'gold', 'dead_letter', 'heartbeat')),
    severity        text        not null default 'warning'
                                check (severity in ('info', 'warning', 'critical')),
    title           text        not null,
    body            text,
    created_at      timestamptz not null default now(),
    status          text        not null default 'pending'
                                check (status in ('pending', 'sending', 'sent', 'failed', 'dead', 'disabled')),
    attempts        int         not null default 0,
    next_attempt_at timestamptz not null default now(),
    claimed_at      timestamptz,
    sent_at         timestamptz,
    last_error      text,
    channel         text        not null default 'slack'
);

alter table ops.alert_outbox enable row level security;

create index if not exists alert_outbox_pending_idx
    on ops.alert_outbox (next_attempt_at) where status = 'pending';

comment on table ops.alert_outbox is
  'Alert delivery queue. One row per dedupe_key; triggers insert from alert log tables. '
  'Claimed by the alert-dispatch edge function and marked sent/failed. '
  'delivery controlled by silver.sidnl_config.alert_delivery_enabled.';

-- 3a. Trigger on ops.cron_alert_log
create or replace function ops.cron_alert_to_outbox()
returns trigger
language plpgsql
security definer
set search_path = ops, silver, public, pg_temp
as $$
begin
    insert into ops.alert_outbox (dedupe_key, source, severity, title, body)
    values (
        'cron:' || new.alert_id::text,
        'cron',
        case when new.level = 'alert' then 'warning' else 'info' end,
        new.jobname || ': ' || new.level,
        coalesce(
            new.consecutive_failures::text || ' consecutive failure(s). Last: ' || left(new.last_failure_message, 400),
            new.level
        )
    )
    on conflict (dedupe_key) do nothing;
    return new;
exception
    when others then
        raise warning 'cron_alert_to_outbox: %', sqlerrm;
        return new;
end $$;

drop trigger if exists trg_cron_alert_outbox on ops.cron_alert_log;
create trigger trg_cron_alert_outbox
    after insert on ops.cron_alert_log
    for each row execute function ops.cron_alert_to_outbox();

-- 3b. Trigger on ops.storage_alert_log
create or replace function ops.storage_alert_to_outbox()
returns trigger
language plpgsql
security definer
set search_path = ops, silver, public, pg_temp
as $$
begin
    insert into ops.alert_outbox (dedupe_key, source, severity, title, body)
    values (
        'storage:' || new.alert_id::text,
        'storage',
        case when new.level = 'critical' then 'critical'
             when new.level = 'warning'  then 'warning'
             else 'info' end,
        'storage ' || new.level,
        coalesce(
            new.message || ' (' || new.used_pct::text || '%)',
            'storage level: ' || new.level
        )
    )
    on conflict (dedupe_key) do nothing;
    return new;
exception
    when others then
        raise warning 'storage_alert_to_outbox: %', sqlerrm;
        return new;
end $$;

drop trigger if exists trg_storage_alert_outbox on ops.storage_alert_log;
create trigger trg_storage_alert_outbox
    after insert on ops.storage_alert_log
    for each row execute function ops.storage_alert_to_outbox();

-- 4. Claim API
create or replace function ops.alert_claim(p_limit int default 10)
returns table (
    alert_id  bigint,
    source    text,
    severity  text,
    title     text,
    body      text,
    attempts  int
)
language plpgsql
security definer
set search_path = ops, silver, public, pg_temp
as $$
begin
    if coalesce(silver.cfg('alert_delivery_enabled'), 0) <> 1 then
        return;
    end if;

    update ops.alert_outbox
       set status     = 'failed',
           last_error = 'reclaimed: stuck in sending past claim timeout'
     where status     = 'sending'
       and claimed_at < now() - make_interval(mins => coalesce(silver.cfg('alert_claim_timeout_minutes'), 5));

    return query
    update ops.alert_outbox o
       set status     = 'sending',
           claimed_at = now(),
           attempts   = o.attempts + 1
     where o.alert_id in (
        select a.alert_id
          from ops.alert_outbox a
         where a.status = 'pending'
           and a.next_attempt_at <= now()
         order by a.alert_id
         for update skip locked
         limit p_limit
     )
     returning o.alert_id, o.source, o.severity, o.title, o.body, o.attempts;
end $$;

comment on function ops.alert_claim(int) is
  'Called by alert-dispatch edge function: returns up to p_limit pending rows and marks them sending. '
  'Returns nothing when alert_delivery_enabled = 0.';

-- 5. Mark API
create or replace function ops.alert_mark(
    p_alert_id  bigint,
    p_ok        bool,
    p_err       text default null
)
returns void
language plpgsql
security definer
set search_path = ops, silver, public, pg_temp
as $$
begin
    if p_ok then
        update ops.alert_outbox
           set status     = 'sent',
               sent_at    = now(),
               last_error = null
         where alert_id   = p_alert_id;
    else
        update ops.alert_outbox o
           set status          = case
                                     when o.attempts >= coalesce(silver.cfg('alert_max_attempts'), 6) then 'dead'
                                     else 'pending'
                                 end,
               next_attempt_at = now() + make_interval(mins => silver.backoff_minutes(o.attempts)),
               last_error      = p_err
         where o.alert_id = p_alert_id;
    end if;
end $$;

comment on function ops.alert_mark(bigint, bool, text) is
  'Called by alert-dispatch: marks a row sent (p_ok=true) or schedules a retry / marks dead (p_ok=false).';

-- 6. Health view
create or replace view ops.v_alert_outbox_health
with (security_invoker = true) as
select
    count(*)                                    filter (where status = 'pending')  as pending,
    count(*)                                    filter (where status = 'sending')  as sending,
    count(*)                                    filter (where status = 'sent')     as sent,
    count(*)                                    filter (where status = 'failed')   as failed,
    count(*)                                    filter (where status = 'dead')     as dead,
    max(now() - created_at)                     filter (where status = 'pending')  as oldest_pending_age
from ops.alert_outbox;

comment on view ops.v_alert_outbox_health is
  'Quick health summary for the alert outbox. pending > 0 means delivery is behind. '
  'dead > 0 needs attention. All zero when alert_delivery_enabled = 0.';
