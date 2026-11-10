-- =============================================================================
-- File:    20261110121500_silver_063_dead_letter.sql
-- Gap:     3 (fallbacks-design.md) — dead-letter quarantine, Option A
-- Status:  IMPLEMENTS GAP 3 (decision: Option A, 2026-11-10).
--
-- WHAT IS AUTOMATED HERE:
--   * ops.dead_letter table + health views
--   * silver.isolate_bad_rows(): binary-search a failed bronze id range to
--     pinpoint the offending row(s) using ANY chunk loader that accepts
--     (lo, hi) id bounds — generic via a format template.
--   * silver.retry_dead_letters(): re-run quarantined rows; auto-resolve or
--     stop retrying after max attempts; alerts via outbox (062).
--
-- WHAT NEEDS THE LIVE FUNCTION TEXT (admin, Phase 3):
--   * The one-predicate change to refresh_category_scope / refresh_brand
--     loaders:  "and not exists (select 1 from ops.dead_letter d
--     where d.status='open' and d.source_table=<bronze table>
--     and d.bronze_id=<bronze id>)".  Add it with create-or-replace against
--     the live definitions (save old text to ops.function_backup first).
-- Rollback: 063_rollback.sql
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Config
-- ---------------------------------------------------------------------------
insert into silver.sidnl_config(key, value_num, description) values
  ('dead_letter_retry_minutes', 60, 'how often retry_dead_letters runs from run_tick'),
  ('dead_letter_max_retries',   24, 'retries before a row stays open but stops auto-retrying')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Dead-letter table (rows are never deleted)
-- ---------------------------------------------------------------------------
create table if not exists ops.dead_letter(
  dl_id               bigint generated always as identity primary key,
  source_table        text not null,            -- bronze table name
  bronze_id           bigint not null,          -- the id in the bronze table
  platform            text,
  scope               text,                     -- brand/scope that failed
  reason              text not null,            -- error text / SQLSTATE
  sqlstate            text,
  loader_sql          text not null,            -- format template: %(lo)s %(hi)s
  first_seen_at       timestamptz not null default now(),
  last_tried_at       timestamptz,
  retry_count         int not null default 0,
  status              text not null default 'open'
                      check (status in ('open','resolved','ignored')),
  resolved_at         timestamptz,
  resolved_by         text,
  unique (source_table, bronze_id)
);
alter table ops.dead_letter enable row level security;

create or replace view ops.v_dead_letter_open
with (security_invoker = true) as
select count(*) as open_rows,
       count(*) filter (where retry_count >= silver.cfg('dead_letter_max_retries')) as exhausted
from ops.dead_letter where status = 'open';

-- ---------------------------------------------------------------------------
-- 3. Bisect: find the exact bad row(s) in a failed [lo, hi) id range.
--    p_loader_sql must be a format() template that inserts bronze rows with
--    ids in [%(lo)s, %(hi)s) into silver, e.g. the failing loader's insert
--    restricted to the id window. It must raise on the bad row.
-- ---------------------------------------------------------------------------
create or replace function silver.isolate_bad_rows(
  p_source_table text,
  p_scope        text,
  p_lo           bigint,
  p_hi           bigint,
  p_loader_sql   text,
  p_depth        int default 0
) returns int                     -- number of rows dead-lettered at this level
language plpgsql security definer as $$
declare
  v_mid    bigint;
  v_sqlstate text;
begin
  if p_hi - p_lo <= 1 or p_depth > 32 then
    -- single row (or exhausted depth): quarantine it
    begin
      execute format(p_loader_sql, p_lo, p_hi);   -- try the single row once more
      return 0;                                   -- it passed now: transient
    exception when others then
      get stacked diagnostics v_sqlstate = RETURNED_SQLSTATE;
      insert into ops.dead_letter(source_table, bronze_id, scope, reason, sqlstate, loader_sql)
      values (p_source_table, p_lo, p_scope, sqlerrm, v_sqlstate, p_loader_sql)
      on conflict (source_table, bronze_id) do update
        set reason = excluded.reason, sqlstate = excluded.sqlstate,
            last_tried_at = now(), retry_count = ops.dead_letter.retry_count + 1;
      return 1;
    end;
  end if;

  v_mid := p_lo + (p_hi - p_lo) / 2;

  begin
    execute format(p_loader_sql, p_lo, v_mid);     -- lower half
  exception when others then
    perform silver.isolate_bad_rows(p_source_table, p_scope, p_lo, v_mid, p_loader_sql, p_depth + 1);
  end;

  begin
    execute format(p_loader_sql, v_mid, p_hi);     -- upper half
  exception when others then
    perform silver.isolate_bad_rows(p_source_table, p_scope, v_mid, p_hi, p_loader_sql, p_depth + 1);
  end;

  return 0;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Retry loop (call from run_tick every dead_letter_retry_minutes)
-- ---------------------------------------------------------------------------
create or replace function silver.retry_dead_letters(p_force bool default false)
returns int
language plpgsql security definer as $$
declare
  r        record;
  v_max    int  := silver.cfg('dead_letter_max_retries');
  v_fixed  int  := 0;
begin
  for r in
    select * from ops.dead_letter
     where status = 'open'
       and (p_force or retry_count < v_max)
     order by dl_id
     for update skip locked
  loop
    begin
      -- retry exactly the quarantined row
      execute format(r.loader_sql, r.bronze_id, r.bronze_id + 1);
      update ops.dead_letter
         set status='resolved', resolved_at=now(), resolved_by='auto-retry'
       where dl_id = r.dl_id;
      v_fixed := v_fixed + 1;
    exception when others then
      update ops.dead_letter
         set retry_count = retry_count + 1, last_tried_at = now(),
             reason = sqlerrm
       where dl_id = r.dl_id;
      insert into ops.alert_outbox(dedupe_key, source, severity, title, body)
      values ('dead_letter:' || r.dl_id::text, 'dead_letter', 'warning',
              'Dead-letter retry failed: ' || r.source_table || '#' || r.bronze_id::text,
              sqlerrm)
      on conflict (dedupe_key) do nothing;
    end;
  end loop;
  return v_fixed;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Scope health view (degraded when anything is open)
-- ---------------------------------------------------------------------------
create or replace view ops.v_scope_health
with (security_invoker = true) as
select scope,
       count(*) filter (where status='open')                       as open_rows,
       bool_or(status='open')                                      as degraded
from ops.dead_letter
group by scope;

-- ---------------------------------------------------------------------------
-- 6. HOOK INTO run_tick (Phase 3, needs live text):
--    inside silver.run_tick(), after the existing checks:
--      perform silver.retry_dead_letters()
--        where silver.cfg('dead_letter_retry_minutes') > 0;
-- ---------------------------------------------------------------------------
