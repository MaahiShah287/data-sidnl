-- silver_060_store_city_from_snapshots
-- 191 bronze stores (public.stores) have no city_slug, but the scrape snapshots taken at those stores
-- (public.shelf_snapshots / public.search_snapshots) record the city. Silver took the city only from the store, so
-- 114,515 shelf facts (6.2%) and 162 readings had no city and showed as "(unknown)" city on the dashboard.
-- Evidence check on 2026-11-10 (city on each bronze snapshot behind the store's facts): 189 of the 191 city-less
-- stores have ONE city on all their snapshots; 2 (Delhi/Gurugram border) have two and stay NULL. Where both are known,
-- store city and snapshot city agree in 10,838 of 10,852 snapshots (99.87%).
-- Fix (bronze is only read):
--   1. silver.fill_store_cities(): a store with no city gets the single city all of its snapshots report (stores whose
--      snapshots disagree, or that have none, stay NULL). Every fill is logged in ops.store_city_filled.
--      Facts of those stores take the store's city (the loaders already take city from silver.dim_store).
--   2. refresh_brand's dim_store upsert no longer overwrites a known city with NULL (coalesce); exactly one place patched.
--   3. Partial indexes so finding city-less facts stays cheap as facts grow.
--   4. Cron job sidnl-store-city (every 10 min); after any fill, gold is re-queued.

insert into ops.function_backup (fn, tag, definition)
select 'silver.refresh_brand(text,boolean)', 'pre_silver_060', pg_get_functiondef('silver.refresh_brand(text,boolean)'::regprocedure);

do $patch$
declare
    d   text := pg_get_functiondef('silver.refresh_brand(text,boolean)'::regprocedure);
    a   text := 'store_name = excluded.store_name, city_slug = excluded.city_slug,';
    a2  text := 'store_name = excluded.store_name, city_slug = coalesce(excluded.city_slug, silver.dim_store.city_slug),';
    b   text := 'is distinct from (excluded.store_name, excluded.city_slug, excluded.latitude';
    b2  text := 'is distinct from (excluded.store_name, coalesce(excluded.city_slug, silver.dim_store.city_slug), excluded.latitude';
begin
    if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'silver_060: patch A must match exactly once'; end if;
    if (length(d) - length(replace(d, b, ''))) / length(b) <> 1 then raise exception 'silver_060: patch B must match exactly once'; end if;
    execute replace(replace(d, a, a2), b, b2);
end $patch$;

create table ops.store_city_filled (
    store_key       integer primary key,
    source_store_id integer not null,
    city_slug       text not null,
    snapshots       integer not null,
    filled_at       timestamptz not null default now()
);
alter table ops.store_city_filled enable row level security;
comment on table ops.store_city_filled is
  'silver_060: stores whose city came from their bronze scrape snapshots (public.stores had no city). One unanimous city per store.';

create index ix_fsp_null_city on silver.fact_shelf_position (store_key) where city_slug is null;
create index ix_reading_null_city on silver.fact_product_reading (store_key) where city_slug is null;

create or replace function silver.fill_store_cities()
 returns jsonb
 language plpgsql
 set search_path to 'silver', 'ops', 'public', 'pg_temp'
as $function$
declare v_st int := 0; v_sh bigint := 0; v_rd bigint := 0;
begin
    if not exists (select 1 from silver.dim_store where city_slug is null)
       and not exists (select 1 from silver.fact_shelf_position f join silver.dim_store ds using (store_key)
                        where f.city_slug is null and ds.city_slug is not null)
       and not exists (select 1 from silver.fact_product_reading f join silver.dim_store ds using (store_key)
                        where f.city_slug is null and ds.city_slug is not null) then
        return jsonb_build_object('status', 'nothing to do');
    end if;
    if not pg_try_advisory_xact_lock(727100) then
        return jsonb_build_object('status', 'skipped', 'reason', 'pipeline run in progress');
    end if;

    -- evidence = the city recorded on every bronze snapshot that produced a fact (or a snapshot) for the store
    with need as (select store_key, source_store_id from silver.dim_store where city_slug is null),
    ev as (
        select z.store_key, min(z.city_slug) as city_slug, count(*) as n
          from (select f.store_key, ss.city_slug
                  from silver.fact_shelf_position f
                  join public.shelf_snapshots ss on ss.id = f.snapshot_id
                 where f.city_slug is null and f.store_key in (select store_key from need) and ss.city_slug is not null
                union all
                select f.store_key, s.city_slug
                  from silver.fact_product_reading f
                  join public.search_snapshots s on s.id = f.snapshot_id
                 where f.source_table = 'public.search_cards' and f.city_slug is null
                   and f.store_key in (select store_key from need) and s.city_slug is not null
                union all
                select f.store_key, ss.city_slug
                  from silver.fact_product_reading f
                  join public.shelf_snapshots ss on ss.id = f.snapshot_id
                 where f.source_table = 'public.shelf_positions' and f.city_slug is null
                   and f.store_key in (select store_key from need) and ss.city_slug is not null
                union all
                select n.store_key, ss.city_slug from need n join public.shelf_snapshots ss on ss.store_id = n.source_store_id
                 where ss.city_slug is not null
                union all
                select n.store_key, s.city_slug from need n join public.search_snapshots s on s.store_id = n.source_store_id
                 where s.city_slug is not null) z
         group by z.store_key
        having count(distinct z.city_slug) = 1),
    upd as (
        update silver.dim_store ds set city_slug = ev.city_slug
          from ev
         where ds.store_key = ev.store_key and ds.city_slug is null
           and exists (select 1 from silver.dim_city c where c.city_slug = ev.city_slug)
        returning ds.store_key, ds.source_store_id, ds.city_slug, ev.n)
    insert into ops.store_city_filled (store_key, source_store_id, city_slug, snapshots)
    select store_key, source_store_id, city_slug, n from upd
    on conflict (store_key) do update set city_slug = excluded.city_slug, snapshots = excluded.snapshots, filled_at = now();
    get diagnostics v_st = row_count;

    update silver.fact_shelf_position f set city_slug = ds.city_slug
      from silver.dim_store ds
     where f.city_slug is null and f.store_key = ds.store_key and ds.city_slug is not null;
    get diagnostics v_sh = row_count;

    update silver.fact_product_reading f set city_slug = ds.city_slug
      from silver.dim_store ds
     where f.city_slug is null and f.store_key = ds.store_key and ds.city_slug is not null;
    get diagnostics v_rd = row_count;

    if v_st + v_sh + v_rd > 0 then
        update ops.pipeline_run set gold_status = 'pending'
         where run_id = (select max(run_id) from ops.pipeline_run where status = 'success') and gold_status is distinct from 'pending';
    end if;
    return jsonb_build_object('status', 'ok', 'stores_filled', v_st, 'shelf_facts_updated', v_sh, 'readings_updated', v_rd);
end $function$;

comment on function silver.fill_store_cities() is
  'sidnl-store-city: gives a city-less store the single city its bronze snapshots report, then sets that city on its facts (silver_060).';

select silver.fill_store_cities();

select cron.schedule('sidnl-store-city', '*/10 * * * *',
                     $cmd$set statement_timeout = '300s'; select silver.fill_store_cities()$cmd$);
