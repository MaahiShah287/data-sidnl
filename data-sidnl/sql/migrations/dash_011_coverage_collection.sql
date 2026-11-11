-- dash_011_coverage_collection   (needs silver_070)
-- Two front-end tables from the new silver context facts, rebuilt by dash.refresh_context():
--   dash.coverage           date x platform x city x source: points checked / serviceable (num + den), stores serving
--   dash.collection_health  date x platform x job type: runs, failed runs, stores planned / done / failed, blocked,
--                           requests, store completion % (num + den)
-- Plus cron job sidnl-context (every 10 min): silver.refresh_scrape_context() then dash.refresh_context().
-- Kept apart from dash.refresh() on purpose: the ~40 s main gold rebuild is untouched, and a failure here never
-- holds back pricing / availability / visibility.

create table if not exists dash.coverage (
    obs_date            date not null,
    platform            text not null,
    city_slug           text not null,
    source_type         text not null,
    points_checked      integer not null,
    points_serviceable  integer not null,
    serviceable_pct     numeric(6,2),
    stores_serving      integer not null,
    refreshed_at        timestamptz not null default now(),
    primary key (obs_date, platform, city_slug, source_type)
);
alter table dash.coverage enable row level security;

create table if not exists dash.collection_health (
    obs_date             date not null,
    platform             text not null,
    job_type             text not null,
    runs                 integer not null,
    runs_ok              integer not null,
    runs_partial         integer not null,
    runs_failed          integer not null,
    runs_unfinished      integer not null,
    stores_planned       integer,
    stores_done          integer,
    stores_failed        integer,
    store_completion_pct numeric(6,2),
    blocked              integer,
    requests             integer,
    shelf_reads          integer,
    shelf_reads_ok       integer,
    refreshed_at         timestamptz not null default now(),
    primary key (obs_date, platform, job_type)
);
alter table dash.collection_health enable row level security;

CREATE OR REPLACE FUNCTION dash.refresh_context()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'dash', 'silver', 'public', 'pg_temp'
AS $function$
declare n_cov bigint; n_col bigint;
begin
    -- one answer per point per day: a point counts as serviceable when any store delivered there that day
    delete from dash.coverage;
    insert into dash.coverage (obs_date, platform, city_slug, source_type, points_checked, points_serviceable,
                               serviceable_pct, stores_serving)
    with pt as (
        select f.obs_date, f.platform, coalesce(f.city_slug, '(unknown)') as city_slug, f.source_type,
               coalesce(f.sample_point_id::text, f.latitude::text || ',' || f.longitude::text) as point,
               bool_or(f.is_serviceable) as served
          from silver.fact_serviceability f
          join silver.dim_platform pl on pl.platform = f.platform and not pl.is_test
         where f.dq_status = 'valid' and f.obs_date is not null
         group by 1, 2, 3, 4, 5),
    st as (
        select f.obs_date, f.platform, coalesce(f.city_slug, '(unknown)') as city_slug, f.source_type,
               count(distinct f.source_store_id) filter (where f.is_serviceable) as stores
          from silver.fact_serviceability f
         where f.dq_status = 'valid' and f.obs_date is not null
         group by 1, 2, 3, 4)
    select pt.obs_date, pt.platform, pt.city_slug, pt.source_type, count(*), count(*) filter (where pt.served),
           round(100.0 * count(*) filter (where pt.served) / nullif(count(*), 0), 2), coalesce(max(st.stores), 0)
      from pt
      left join st using (obs_date, platform, city_slug, source_type)
     group by 1, 2, 3, 4;
    get diagnostics n_cov = row_count;

    delete from dash.collection_health;
    insert into dash.collection_health (obs_date, platform, job_type, runs, runs_ok, runs_partial, runs_failed,
                                        runs_unfinished, stores_planned,
                                        stores_done, stores_failed, store_completion_pct, blocked, requests,
                                        shelf_reads, shelf_reads_ok)
    with r as (
        select (r.started_at at time zone 'Asia/Kolkata')::date as obs_date, coalesce(r.platform, '(unknown)') as platform,
               r.job_type, r.job_id, r.status, r.finished_at,
               coalesce(r.stores_planned, r.points_planned) as planned,
               -- check runs can report more points done than planned: a run never counts above 100 %
               least(coalesce(r.stores_done, r.points_done), coalesce(r.stores_planned, r.points_planned)) as done,
               -- bronze status words: done | failed, blocked | partial, stopped, interrupted (+ running while open)
               case when r.finished_at is null then 'open'
                    when r.status ~* '^(done|ok|success|completed?)$' then 'ok'
                    when r.status ~* '(fail|error|blocked|abort|cancel)' then 'failed'
                    else 'partial' end as outcome,
               r.stores_failed, r.blocked, r.requests
          from silver.fact_scrape_run r
         where r.started_at is not null),
    sh as (
        select s.obs_date, s.platform, s.sweep_id, count(*) as reads, count(*) filter (where s.read_ok) as ok
          from silver.fact_shelf_snapshot s where s.sweep_id is not null group by 1, 2, 3)
    select r.obs_date, r.platform, r.job_type, count(*),
           count(*) filter (where r.outcome = 'ok'), count(*) filter (where r.outcome = 'partial'),
           count(*) filter (where r.outcome = 'failed'), count(*) filter (where r.outcome = 'open'),
           sum(r.planned), sum(r.done), sum(r.stores_failed),
           round(100.0 * sum(r.done) / nullif(sum(r.planned), 0), 2),
           sum(r.blocked), sum(r.requests),
           sum(sh.reads), sum(sh.ok)
      from r
      left join sh on r.job_type = 'category_sweep' and sh.sweep_id = r.job_id and sh.obs_date = r.obs_date
     group by 1, 2, 3;
    get diagnostics n_col = row_count;

    insert into dash.refresh_state (key, value, updated_at)
    values ('context_refreshed_at', now()::text, now())
    on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at;

    return jsonb_build_object('coverage', n_cov, 'collection_health', n_col, 'refreshed_at', now());
end $function$
;

comment on table dash.coverage is 'Serviceability per day x platform x city x source (check_point / coverage / fulfilment_probe). serviceable_pct = points_serviceable / points_checked; roll up as SUM/SUM. Not serviceable is never out of stock.';
comment on table dash.collection_health is 'Scrape runs per day x platform x job type: ok (done) / partial (partial, stopped, interrupted) / failed (failed, blocked) / unfinished runs, store completion (done capped at planned per run, / planned), blocked, requests; category sweeps also count shelf reads and reads that worked.';
comment on function dash.refresh_context() is 'Rebuilds dash.coverage and dash.collection_health from silver (dash_011). Called by cron sidnl-context after silver.refresh_scrape_context().';

-- the job: silver first; dash only after it, in the same transaction
select cron.schedule('sidnl-context', '*/10 * * * *',
       'set statement_timeout = ''300s''; select silver.refresh_scrape_context(); select dash.refresh_context()');
