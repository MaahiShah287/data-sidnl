-- silver_062_bronze_freshness  (Gap 2 of docs/fallbacks-design.md)
-- Per-platform, per-source freshness measured on BRONZE, so the dashboard can say "data stale since X" instead of
-- presenting old numbers as current. Bronze is only read.
--   sources: category_shelf = public.shelf_snapshots.taken_at, brand_search = public.search_snapshots.taken_at,
--            stock_check = public.observations.observed_at (platform via public.platform_listings)
--   a snapshot with status 'ok' or 'empty' counts as data arriving; 'failed' only as an attempt
--   thresholds: silver.freshness_policy.fresh_within_hours (existing, one row per source) with optional per-platform
--   overrides in ops.freshness_override (also used to mark a platform/source as not expected)
--   platforms: every non-test platform in silver.dim_platform PLUS any platform seen in bronze, so a new platform
--   (e.g. Flipkart Minutes, BigBasket, Amazon Now) is monitored from its first bronze row without configuration
-- Scale: silver.refresh_freshness() reads only bronze rows with id above a cursor (primary-key range scan, with a small
-- look-back for late commits), so each run costs O(new rows). Cron sidnl-freshness every 5 minutes.
-- Status changes are logged in ops.freshness_event, and a stale platform/source writes an alert row to
-- ops.cron_alert_log (jobname 'freshness:<platform>/<source>', not a cron job name).

insert into silver.sidnl_config (key, value_num, description) values
  ('freshness_lookback_rows', 1000, 'sidnl-freshness re-reads this many bronze ids below its cursor each run (late-committed rows)')
on conflict (key) do nothing;

create table ops.freshness_cursor (
    source_table text primary key,
    last_id      bigint not null default 0,
    updated_at   timestamptz not null default now()
);

create table ops.freshness_state (
    platform        text not null,
    source_type     text not null references silver.freshness_policy (source_type),
    last_ok_at      timestamptz,
    last_attempt_at timestamptz,
    last_failed_at  timestamptz,
    last_status     text,
    status_since    timestamptz,
    updated_at      timestamptz not null default now(),
    primary key (platform, source_type)
);

create table ops.freshness_override (
    platform           text not null,
    source_type        text not null references silver.freshness_policy (source_type),
    expected           boolean not null default true,
    fresh_within_hours integer,
    note               text,
    primary key (platform, source_type)
);

create table ops.freshness_event (
    event_id    bigint generated always as identity primary key,
    at          timestamptz not null default now(),
    platform    text not null,
    source_type text not null,
    from_status text,
    to_status   text not null,
    last_ok_at  timestamptz
);

alter table ops.freshness_cursor enable row level security;
alter table ops.freshness_state enable row level security;
alter table ops.freshness_override enable row level security;
alter table ops.freshness_event enable row level security;
comment on table ops.freshness_state is 'silver_062: latest bronze row time per platform x source (maintained by silver.refresh_freshness).';
comment on table ops.freshness_override is 'silver_062: optional per-platform threshold, or expected=false for a source a platform is not scraped for.';
comment on table ops.freshness_event is 'silver_062: every freshness status change (fresh/stale/never_seen/not_expected).';

create view dash.v_data_freshness with (security_invoker = true) as
with plat as (
    select platform from silver.dim_platform where not is_test
    union
    select platform from ops.freshness_state
     where platform not in (select platform from silver.dim_platform where is_test)
), k as (
    select p.platform, fp.source_type, fp.fresh_within_hours from plat p cross join silver.freshness_policy fp
)
select k.platform, k.source_type,
       st.last_ok_at, st.last_attempt_at, st.last_failed_at,
       round(extract(epoch from now() - st.last_ok_at) / 3600, 1) as age_hours,
       coalesce(o.fresh_within_hours, k.fresh_within_hours) as max_age_hours,
       case when o.expected = false then 'not_expected'
            when st.last_ok_at is null then 'never_seen'
            when now() - st.last_ok_at <= make_interval(hours => coalesce(o.fresh_within_hours, k.fresh_within_hours)) then 'fresh'
            else 'stale' end as status,
       (st.last_failed_at is not null and (st.last_ok_at is null or st.last_failed_at > st.last_ok_at)) as latest_attempt_failed,
       st.status_since
  from k
  left join ops.freshness_state st on st.platform = k.platform and st.source_type = k.source_type
  left join ops.freshness_override o on o.platform = k.platform and o.source_type = k.source_type;
comment on view dash.v_data_freshness is
  'Bronze freshness per platform x source. status: fresh | stale (had data, nothing new within max_age_hours) | never_seen (no bronze row ever) | not_expected (ops.freshness_override). latest_attempt_failed = the scraper ran but its newest attempt failed.';

create view dash.v_platform_freshness with (security_invoker = true) as
select platform,
       case when bool_and(status in ('never_seen', 'not_expected')) then 'no_data'
            when bool_or(status = 'stale') then 'stale'
            else 'fresh' end as status,
       max(last_ok_at) as last_data_at,
       round(extract(epoch from now() - max(last_ok_at)) / 3600, 1) as hours_since_last_data,
       coalesce(array_agg(source_type order by source_type) filter (where status = 'stale'), '{}') as stale_sources,
       coalesce(array_agg(source_type order by source_type) filter (where status = 'fresh'), '{}') as fresh_sources,
       coalesce(array_agg(source_type order by source_type) filter (where status = 'never_seen'), '{}') as never_seen_sources
  from dash.v_data_freshness
 group by platform;
comment on view dash.v_platform_freshness is
  'One row per platform for the "data stale" banner: no_data | stale (any source that had data is stale) | fresh.';

create or replace function silver.refresh_freshness()
 returns jsonb
 language plpgsql
 set search_path to 'silver', 'ops', 'public', 'pg_temp'
as $function$
declare
    v_lb bigint := coalesce(silver.cfg('freshness_lookback_rows'), 1000)::bigint;
    v_lo bigint; v_max bigint; v_ev int := 0;
begin
    if not pg_try_advisory_xact_lock(727103) then
        return jsonb_build_object('status', 'skipped', 'reason', 'already running');
    end if;

    -- category_shelf <- public.shelf_snapshots
    select greatest(coalesce((select last_id from ops.freshness_cursor where source_table = 'public.shelf_snapshots'), 0) - v_lb, 0) into v_lo;
    select coalesce(max(id), 0) into v_max from public.shelf_snapshots;
    insert into ops.freshness_state as t (platform, source_type, last_ok_at, last_attempt_at, last_failed_at, updated_at)
    select lower(btrim(platform::text)), 'category_shelf',
           max(taken_at) filter (where status in ('ok', 'empty')), max(taken_at), max(taken_at) filter (where status = 'failed'), now()
      from public.shelf_snapshots where id > v_lo and id <= v_max and platform is not null
     group by 1
    on conflict (platform, source_type) do update set
        last_ok_at      = greatest(t.last_ok_at, excluded.last_ok_at),
        last_attempt_at = greatest(t.last_attempt_at, excluded.last_attempt_at),
        last_failed_at  = greatest(t.last_failed_at, excluded.last_failed_at),
        updated_at      = now();
    insert into ops.freshness_cursor (source_table, last_id) values ('public.shelf_snapshots', v_max)
    on conflict (source_table) do update set last_id = greatest(ops.freshness_cursor.last_id, excluded.last_id), updated_at = now();

    -- brand_search <- public.search_snapshots
    select greatest(coalesce((select last_id from ops.freshness_cursor where source_table = 'public.search_snapshots'), 0) - v_lb, 0) into v_lo;
    select coalesce(max(id), 0) into v_max from public.search_snapshots;
    insert into ops.freshness_state as t (platform, source_type, last_ok_at, last_attempt_at, last_failed_at, updated_at)
    select lower(btrim(platform::text)), 'brand_search',
           max(taken_at) filter (where status in ('ok', 'empty')), max(taken_at), max(taken_at) filter (where status = 'failed'), now()
      from public.search_snapshots where id > v_lo and id <= v_max and platform is not null
     group by 1
    on conflict (platform, source_type) do update set
        last_ok_at      = greatest(t.last_ok_at, excluded.last_ok_at),
        last_attempt_at = greatest(t.last_attempt_at, excluded.last_attempt_at),
        last_failed_at  = greatest(t.last_failed_at, excluded.last_failed_at),
        updated_at      = now();
    insert into ops.freshness_cursor (source_table, last_id) values ('public.search_snapshots', v_max)
    on conflict (source_table) do update set last_id = greatest(ops.freshness_cursor.last_id, excluded.last_id), updated_at = now();

    -- stock_check <- public.observations (platform from its listing)
    select greatest(coalesce((select last_id from ops.freshness_cursor where source_table = 'public.observations'), 0) - v_lb, 0) into v_lo;
    select coalesce(max(id), 0) into v_max from public.observations;
    insert into ops.freshness_state as t (platform, source_type, last_ok_at, last_attempt_at, updated_at)
    select lower(btrim(l.platform::text)), 'stock_check', max(o.observed_at), max(o.observed_at), now()
      from public.observations o join public.platform_listings l on l.id = o.listing_id
     where o.id > v_lo and o.id <= v_max and l.platform is not null
     group by 1
    on conflict (platform, source_type) do update set
        last_ok_at      = greatest(t.last_ok_at, excluded.last_ok_at),
        last_attempt_at = greatest(t.last_attempt_at, excluded.last_attempt_at),
        updated_at      = now();
    insert into ops.freshness_cursor (source_table, last_id) values ('public.observations', v_max)
    on conflict (source_table) do update set last_id = greatest(ops.freshness_cursor.last_id, excluded.last_id), updated_at = now();

    -- status changes -> event log (+ alert row when something goes stale)
    with cur as (select platform, source_type, status, last_ok_at from dash.v_data_freshness),
    chg as (
        select c.*, s.last_status as prev
          from cur c left join ops.freshness_state s using (platform, source_type)
         where c.status is distinct from s.last_status),
    ev as (
        insert into ops.freshness_event (platform, source_type, from_status, to_status, last_ok_at)
        select platform, source_type, prev, status, last_ok_at from chg
        returning platform, source_type, from_status, to_status),
    al as (
        insert into ops.cron_alert_log (jobname, level, consecutive_failures, last_failure_message)
        select 'freshness:' || platform || '/' || source_type,
               case when to_status = 'stale' then 'alert' else 'recovered' end, 0,
               format('%s %s is %s (was %s)', platform, source_type, to_status, coalesce(from_status, 'unknown'))
          from ev where to_status = 'stale' or (from_status = 'stale' and to_status = 'fresh')
        returning 1)
    select count(*) into v_ev from ev;

    insert into ops.freshness_state as t (platform, source_type, last_status, status_since)
    select platform, source_type, status, now() from dash.v_data_freshness
    on conflict (platform, source_type) do update set
        last_status  = excluded.last_status,
        status_since = case when t.last_status is distinct from excluded.last_status then now() else t.status_since end;

    return jsonb_build_object('status', 'ok', 'status_changes', v_ev,
                              'stale', (select count(*) from dash.v_data_freshness where status = 'stale'),
                              'fresh', (select count(*) from dash.v_data_freshness where status = 'fresh'));
end $function$;

comment on function silver.refresh_freshness() is 'sidnl-freshness (every 5 min): bronze freshness per platform x source, incremental by id cursor (silver_062).';

select silver.refresh_freshness();

select cron.schedule('sidnl-freshness', '*/5 * * * *',
                     $cmd$set statement_timeout = '120s'; select silver.refresh_freshness()$cmd$);
