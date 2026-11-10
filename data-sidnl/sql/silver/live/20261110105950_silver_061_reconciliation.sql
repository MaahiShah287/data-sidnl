-- silver_061_reconciliation
-- Automated proof that the numbers on the front end are exactly what bronze says. Daily cron job sidnl-reconcile runs
-- silver.reconcile(), logs one row per check in ops.reconciliation_log, and writes an alert row to ops.cron_alert_log
-- (jobname 'sidnl-reconcile:data', which is not a cron job, so check_cron_alert never marks it "recovered") if any
-- check finds a mismatch.
-- Checks (hop 1: silver = bronze, hop 2: dash = silver, computed here by separate SQL, not by dash.refresh):
--   readings_vs_bronze   silver.fact_product_reading vs public.observations / search_cards / shelf_positions
--                        (price, mrp, time, store, platform, product, city) for rows loaded in the window
--   shelf_vs_bronze      silver.fact_shelf_position vs public.shelf_positions + shelf_snapshots, same window
--   dash_pricing         dash.pricing vs a re-aggregation of silver readings (rows missing/extra + value differences)
--   dash_osa             dash.availability OSA counts vs silver readings
--   dash_visibility      dash.visibility category impressions vs silver shelf facts
--   scorecard_totals     dash.v_brand_scorecard brand impressions sum to the market total
-- Expected city = bronze store city, else the unanimous snapshot city recorded in ops.store_city_filled (silver_060).
-- Holds the pipeline (727100) and gold (727101) locks so nothing changes mid-check; dash checks run only when gold is
-- up to date with the latest successful Silver run (otherwise logged as skipped, not as a failure).

insert into silver.sidnl_config (key, value_num, description) values
  ('reconcile_window_days', 3, 'sidnl-reconcile compares silver facts loaded in the last N days with their bronze rows (dash checks are always full)')
on conflict (key) do nothing;

create table ops.reconciliation_log (
    recon_id      bigint generated always as identity primary key,
    run_at        timestamptz not null default now(),
    check_name    text not null,
    status        text not null check (status in ('ok', 'mismatch', 'skipped')),
    rows_checked  bigint,
    mismatches    bigint,
    detail        jsonb
);
alter table ops.reconciliation_log enable row level security;
create index ix_recon_run on ops.reconciliation_log (run_at desc);
comment on table ops.reconciliation_log is 'silver_061: one row per reconciliation check per run (bronze -> silver -> dash).';

create view ops.v_reconciliation_latest with (security_invoker = true) as
select distinct on (check_name) check_name, run_at, status, rows_checked, mismatches, detail
  from ops.reconciliation_log
 order by check_name, run_at desc;
comment on view ops.v_reconciliation_latest is 'Latest result of each reconciliation check; the app can show "data verified at <run_at>".';

create or replace function silver.reconcile()
 returns jsonb
 language plpgsql
 set search_path to 'silver', 'ops', 'public', 'pg_temp'
as $function$
declare
    v_win interval := make_interval(days => coalesce(silver.cfg('reconcile_window_days'), 3)::int);
    v_now timestamptz := now(); r record; v_bad bigint := 0; v_gold_ok boolean; j jsonb;
begin
    if not pg_try_advisory_xact_lock(727100) then return jsonb_build_object('status', 'skipped', 'reason', 'pipeline running'); end if;
    if not pg_try_advisory_xact_lock(727101) then return jsonb_build_object('status', 'skipped', 'reason', 'gold running'); end if;

    -- hop 1a: readings vs bronze
    with b as (
        select 'public.observations' as st, o.id, o.price, o.mrp, o.observed_at as ts, o.store_id, st_.city_slug as city, l.platform, l.external_id as ext
          from public.observations o join public.platform_listings l on l.id = o.listing_id left join public.stores st_ on st_.id = o.store_id
         where o.id in (select source_record_id from silver.fact_product_reading where source_table = 'public.observations' and loaded_at > v_now - v_win)
        union all
        select 'public.search_cards', c.id, c.price, c.mrp, s.taken_at, coalesce(c.store_id, s.store_id), st_.city_slug, s.platform, c.external_id
          from public.search_cards c join public.search_snapshots s on s.id = c.snapshot_id left join public.stores st_ on st_.id = coalesce(c.store_id, s.store_id)
         where c.id in (select source_record_id from silver.fact_product_reading where source_table = 'public.search_cards' and loaded_at > v_now - v_win)
        union all
        select 'public.shelf_positions', p.id, p.price, p.mrp, ss.taken_at, p.store_id, st_.city_slug, ss.platform, p.external_id
          from public.shelf_positions p join public.shelf_snapshots ss on ss.id = p.snapshot_id left join public.stores st_ on st_.id = p.store_id
         where p.id in (select source_record_id from silver.fact_product_reading where source_table = 'public.shelf_positions' and loaded_at > v_now - v_win))
    select count(*) as n,
           count(*) filter (where b.id is null or f.selling_price is distinct from b.price or f.mrp is distinct from b.mrp
                              or f.observed_at is distinct from b.ts or ds.source_store_id is distinct from b.store_id
                              or dp.platform is distinct from b.platform::text or dp.platform_product_id is distinct from b.ext::text
                              or f.city_slug is distinct from coalesce(b.city::text, scf.city_slug)) as bad
      into r
      from silver.fact_product_reading f
      left join b on b.st = f.source_table and b.id = f.source_record_id
      left join silver.dim_store ds on ds.store_key = f.store_key
      left join silver.dim_product dp on dp.product_key = f.product_key
      left join ops.store_city_filled scf on scf.store_key = f.store_key
     where f.loaded_at > v_now - v_win;
    insert into ops.reconciliation_log (run_at, check_name, status, rows_checked, mismatches, detail)
    values (v_now, 'readings_vs_bronze', case when r.bad = 0 then 'ok' else 'mismatch' end, r.n, r.bad, jsonb_build_object('window', v_win::text));
    v_bad := v_bad + r.bad;

    -- hop 1b: shelf facts vs bronze
    select count(*) as n,
           count(*) filter (where s.id is null or f.selling_price is distinct from s.price or f.mrp is distinct from s.mrp
                              or f.inventory_units is distinct from s.inventory or f.shelf_position is distinct from s.position
                              or f.organic_position is distinct from s.organic_position
                              or coalesce(f.is_ad, false) is distinct from coalesce(s.is_ad, false)
                              or f.platform_product_id is distinct from s.external_id::text or f.snapshot_id is distinct from s.snapshot_id
                              or f.observed_at is distinct from ss.taken_at or f.platform is distinct from ss.platform::text
                              or f.city_slug is distinct from coalesce(st_.city_slug::text, scf.city_slug)) as bad
      into r
      from silver.fact_shelf_position f
      left join public.shelf_positions s on s.id = f.source_record_id
      left join public.shelf_snapshots ss on ss.id = s.snapshot_id
      left join public.stores st_ on st_.id = s.store_id
      left join ops.store_city_filled scf on scf.store_key = f.store_key
     where f.loaded_at > v_now - v_win;
    insert into ops.reconciliation_log (run_at, check_name, status, rows_checked, mismatches, detail)
    values (v_now, 'shelf_vs_bronze', case when r.bad = 0 then 'ok' else 'mismatch' end, r.n, r.bad, jsonb_build_object('window', v_win::text));
    v_bad := v_bad + r.bad;

    -- hop 2 only when dash reflects the latest successful Silver run
    select gold_status = 'success' into v_gold_ok from ops.pipeline_run
     where run_id = (select max(run_id) from ops.pipeline_run where status = 'success');
    if not coalesce(v_gold_ok, false) then
        insert into ops.reconciliation_log (run_at, check_name, status, detail)
        select v_now, c, 'skipped', jsonb_build_object('reason', 'gold not yet refreshed for the latest Silver run')
          from unnest(array['dash_pricing', 'dash_osa', 'dash_visibility', 'scorecard_totals']) c;
        return jsonb_build_object('status', case when v_bad = 0 then 'ok' else 'mismatch' end, 'mismatches', v_bad, 'dash_checks', 'skipped');
    end if;

    -- hop 2a: pricing
    with rd as (
        select f.product_key, f.store_key, f.obs_date, d.platform, coalesce(f.city_slug, '(unknown)') as city_slug, x.sidnl_id,
               f.selling_price as sp, f.mrp, f.observed_at, f.reading_key
          from silver.fact_product_reading f
          join silver.dim_product d on d.product_key = f.product_key
          join silver.dim_platform pl on pl.platform = d.platform and not pl.is_test
          join silver.product_xref x on x.product_key = f.product_key
         where f.dq_status = 'valid' and f.store_key is not null and f.selling_price is not null and f.mrp > 0),
    latest as (select distinct on (product_key, store_key, obs_date) * from rd order by product_key, store_key, obs_date, observed_at desc, reading_key desc),
    mine as (select obs_date, platform, city_slug, sidnl_id, count(distinct store_key) as stores, round(avg(mrp), 2) as mrp,
                    round(avg(sp), 2) as sp, min(sp) as mn, max(sp) as mx from latest group by 1, 2, 3, 4)
    select (select count(*) from mine) as n,
           (select count(*) from mine m full join dash.pricing p using (obs_date, platform, city_slug, sidnl_id)
             where m.sidnl_id is null or p.sidnl_id is null
                or (p.stores_observed, p.mrp, p.selling_price, p.min_selling_price, p.max_selling_price)
                   is distinct from (m.stores, m.mrp, m.sp, m.mn, m.mx)) as bad
      into r;
    insert into ops.reconciliation_log (run_at, check_name, status, rows_checked, mismatches)
    values (v_now, 'dash_pricing', case when r.bad = 0 then 'ok' else 'mismatch' end, r.n, r.bad);
    v_bad := v_bad + r.bad;

    -- hop 2b: availability OSA counts
    with mine as (
        select f.obs_date, d.platform, coalesce(f.city_slug, '(unknown)') as city_slug, x.sidnl_id,
               count(*) as oe, count(*) filter (where f.is_available) as oa
          from silver.fact_product_reading f
          join silver.dim_product d on d.product_key = f.product_key
          join silver.dim_platform pl on pl.platform = d.platform and not pl.is_test
          join silver.product_xref x on x.product_key = f.product_key
         where f.dq_status = 'valid' and f.store_key is not null and f.osa_eligible and f.is_available is not null
         group by 1, 2, 3, 4),
    dsh as (select obs_date, platform, city_slug, sidnl_id, osa_eligible_obs as oe, osa_available_obs as oa
              from dash.availability where store_key is null and osa_eligible_obs > 0)
    select (select count(*) from mine) as n,
           (select count(*) from mine m full join dsh a using (obs_date, platform, city_slug, sidnl_id)
             where m.sidnl_id is null or a.sidnl_id is null or (m.oe, m.oa) is distinct from (a.oe, a.oa)) as bad
      into r;
    insert into ops.reconciliation_log (run_at, check_name, status, rows_checked, mismatches)
    values (v_now, 'dash_osa', case when r.bad = 0 then 'ok' else 'mismatch' end, r.n, r.bad);
    v_bad := v_bad + r.bad;

    -- hop 2c: visibility category impressions
    with snap as (
        select distinct on (platform, l1_id, l2_id, store_key, obs_date) snapshot_id
          from silver.fact_shelf_position where store_key is not null
         order by platform, l1_id, l2_id, store_key, obs_date, observed_at desc, snapshot_id desc),
    mine as (
        select f.obs_date, f.platform, coalesce(f.city_slug, '(unknown)') as city_slug, f.l1_id || '>' || f.l2_id as search_term,
               x.sidnl_id, count(*) as impressions
          from silver.fact_shelf_position f
          join snap s on s.snapshot_id = f.snapshot_id
          join silver.product_xref x on x.product_key = f.product_key
          join silver.dim_platform pl on pl.platform = f.platform and not pl.is_test
         where f.dq_status = 'valid' and f.store_key is not null
         group by 1, 2, 3, 4, 5),
    dsh as (select obs_date, platform, city_slug, search_term, sidnl_id, impressions from dash.visibility where search_type = 'category')
    select (select count(*) from mine) as n,
           (select count(*) from mine m full join dsh v using (obs_date, platform, city_slug, search_term, sidnl_id)
             where m.sidnl_id is null or v.sidnl_id is null or m.impressions is distinct from v.impressions) as bad
      into r;
    insert into ops.reconciliation_log (run_at, check_name, status, rows_checked, mismatches)
    values (v_now, 'dash_visibility', case when r.bad = 0 then 'ok' else 'mismatch' end, r.n, r.bad);
    v_bad := v_bad + r.bad;

    -- scorecard totals
    select count(*) as n, count(*) filter (where s <> m) as bad into r
      from (select obs_date, platform, city_slug, sum(shelf_impressions) as s, max(market_shelf_impressions) as m
              from dash.v_brand_scorecard where market_shelf_impressions is not null group by 1, 2, 3) z;
    insert into ops.reconciliation_log (run_at, check_name, status, rows_checked, mismatches)
    values (v_now, 'scorecard_totals', case when r.bad = 0 then 'ok' else 'mismatch' end, r.n, r.bad);
    v_bad := v_bad + r.bad;

    if v_bad > 0 then
        insert into ops.cron_alert_log (jobname, level, consecutive_failures, last_failure_message)
        values ('sidnl-reconcile:data', 'alert', 1,
                left('reconciliation mismatches: ' || (select string_agg(check_name || '=' || mismatches, ', ')
                                                         from ops.reconciliation_log where run_at = v_now and status = 'mismatch'), 500));
    end if;
    return jsonb_build_object('status', case when v_bad = 0 then 'ok' else 'mismatch' end, 'mismatches', v_bad);
end $function$;

comment on function silver.reconcile() is 'sidnl-reconcile (daily): bronze -> silver -> dash reconciliation; see ops.v_reconciliation_latest (silver_061).';

select cron.schedule('sidnl-reconcile', '20 19 * * *',
                     $cmd$set statement_timeout = '900s'; select silver.reconcile()$cmd$);
