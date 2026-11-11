-- silver_070_scrape_context
-- The rest of "Bronze -> Silver: which columns to carry" (2026-11-10), sections 1-3:
--   silver.fact_shelf_snapshot   <- shelf_snapshots   one row per shelf read, every status (a failed read is visible,
--                                                      never shown as out of stock)
--   silver.fact_scrape_run       <- category_sweeps, brand_scrapes, check_runs, product_lookups (one shape, job_type)
--   silver.fact_serviceability   <- check_points, coverage, fulfilment_probes ("not delivered here" != "out of stock")
--   silver.dim_sample_point      <- sample_points
--   silver.dim_listing           <- platform_listings (+ details.brand_id/variant_id/category/subcategory/l3_category_ids)
--   silver.dim_catalog_product   <- products (org_id: which organisation tracks which product)
--   silver.dim_product.source_product_id <- platform_products.id
-- Loaded by silver.refresh_scrape_context() (cron sidnl-context, every 10 min, see dash_011). Each section runs in its
-- own savepoint: one bad section is logged and skipped, the others still load, the main pipeline is never touched.
-- Never copied: demo_requests (personal data), organizations, workspaces, workspace_members, alembic_version,
-- listing_snapshots, brand_logos, fetch_runs, platform_state; fetch_attempts stays row-level in bronze.

do $preflight$
declare v_missing text;
begin
    select string_agg(v.t || '.' || v.c, ', ' order by v.t, v.c) into v_missing
      from (values
        ('shelf_snapshots','id'),('shelf_snapshots','sweep_id'),('shelf_snapshots','platform'),('shelf_snapshots','l1_id'),
        ('shelf_snapshots','l2_id'),('shelf_snapshots','category_name'),('shelf_snapshots','store_id'),
        ('shelf_snapshots','city_slug'),('shelf_snapshots','lat'),('shelf_snapshots','lon'),('shelf_snapshots','status'),
        ('shelf_snapshots','error'),('shelf_snapshots','cards_seen'),('shelf_snapshots','total_items'),
        ('shelf_snapshots','complete'),('shelf_snapshots','taken_at'),
        ('category_sweeps','id'),('category_sweeps','platform'),('category_sweeps','l1_id'),('category_sweeps','l2_id'),
        ('category_sweeps','category_name'),('category_sweeps','trigger'),('category_sweeps','status'),
        ('category_sweeps','cities'),('category_sweeps','stores_planned'),('category_sweeps','stores_done'),
        ('category_sweeps','stores_failed'),('category_sweeps','stores_skipped'),('category_sweeps','requests'),
        ('category_sweeps','started_at'),('category_sweeps','finished_at'),('category_sweeps','error'),
        ('brand_scrapes','id'),('brand_scrapes','org_id'),('brand_scrapes','platform'),('brand_scrapes','query'),
        ('brand_scrapes','brands'),('brand_scrapes','scope'),('brand_scrapes','city_slug'),('brand_scrapes','status'),
        ('brand_scrapes','stores_planned'),('brand_scrapes','stores_done'),('brand_scrapes','stores_failed'),
        ('brand_scrapes','requests'),('brand_scrapes','products_found'),('brand_scrapes','started_at'),
        ('brand_scrapes','finished_at'),('brand_scrapes','error'),
        ('check_runs','id'),('check_runs','org_id'),('check_runs','listing_id'),('check_runs','city_slug'),
        ('check_runs','platform'),('check_runs','status'),('check_runs','started_at'),('check_runs','finished_at'),
        ('check_runs','points_planned'),('check_runs','points_done'),('check_runs','stores_seen'),
        ('check_runs','blocked'),('check_runs','errors'),
        ('product_lookups','id'),('product_lookups','org_id'),('product_lookups','listing_id'),
        ('product_lookups','platform'),('product_lookups','city_slug'),('product_lookups','status'),
        ('product_lookups','stores_planned'),('product_lookups','stores_done'),('product_lookups','stores_failed'),
        ('product_lookups','started_at'),('product_lookups','finished_at'),
        ('check_points','id'),('check_points','run_id'),('check_points','sample_point_id'),('check_points','store_id'),
        ('check_points','serviceable'),
        ('coverage','id'),('coverage','platform'),('coverage','sample_point_id'),('coverage','store_id'),
        ('coverage','serviceable'),('coverage','resolved_at'),
        ('sample_points','id'),('sample_points','city_slug'),('sample_points','pincode'),('sample_points','lat'),
        ('sample_points','lon'),
        ('fulfilment_probes','id'),('fulfilment_probes','platform'),('fulfilment_probes','city_slug'),
        ('fulfilment_probes','lat'),('fulfilment_probes','lon'),('fulfilment_probes','status'),
        ('fulfilment_probes','location_verified'),('fulfilment_probes','serviceable'),('fulfilment_probes','captured_at'),
        ('platform_listings','id'),('platform_listings','product_id'),('platform_listings','platform'),
        ('platform_listings','external_id'),('platform_listings','url'),('platform_listings','name'),
        ('platform_listings','brand'),('platform_listings','pack_size'),('platform_listings','categories'),
        ('platform_listings','price'),('platform_listings','mrp'),('platform_listings','created_at'),
        ('platform_listings','details'),
        ('products','id'),('products','org_id'),('products','name'),('products','brand'),('products','name_source'),
        ('platform_products','id'),('platform_products','platform'),('platform_products','external_id')
      ) v (t, c)
     where not exists (select 1 from information_schema.columns ic
                        where ic.table_schema = 'public' and ic.table_name = v.t and ic.column_name = v.c);
    if v_missing is not null then
        raise exception 'silver_070 preflight: bronze columns not found: %', v_missing;
    end if;
end
$preflight$;

-- ------------------------------------------------------------------------------------------------ tables
create table if not exists silver.fact_shelf_snapshot (
    snapshot_id     bigint primary key,
    sweep_id        bigint,
    platform        text not null,
    l1_id           text,
    l2_id           text,
    category_name   text,
    source_store_id bigint,
    store_key       integer,
    city_slug       text,
    latitude        double precision,
    longitude       double precision,
    read_status     text,
    read_error      text,
    cards_seen      integer,
    total_items     integer,
    is_complete     boolean,
    read_ok         boolean generated always as (coalesce(lower(read_status), '') = 'ok' and is_complete is not false) stored,
    observed_at     timestamptz,
    obs_date        date generated always as (((observed_at at time zone 'Asia/Kolkata'))::date) stored,
    loaded_at       timestamptz not null default now()
);
create index if not exists ix_shelf_snapshot_sweep on silver.fact_shelf_snapshot (sweep_id);
create index if not exists ix_shelf_snapshot_date on silver.fact_shelf_snapshot (obs_date, platform);

create table if not exists silver.fact_scrape_run (
    job_type        text not null check (job_type in ('category_sweep', 'brand_scrape', 'check_run', 'product_lookup')),
    job_id          bigint not null,
    org_id          text,
    platform        text,
    listing_id      bigint,
    l1_id           text,
    l2_id           text,
    category_name   text,
    query           text,
    brands          jsonb,
    scope           text,
    city_slug       text,
    cities          jsonb,
    trigger         text,
    status          text,
    stores_planned  integer,
    stores_done     integer,
    stores_failed   integer,
    stores_skipped  integer,
    points_planned  integer,
    points_done     integer,
    stores_seen     integer,
    blocked         integer,
    errors          integer,
    requests        integer,
    products_found  integer,
    started_at      timestamptz,
    finished_at     timestamptz,
    error           text,
    loaded_at       timestamptz not null default now(),
    primary key (job_type, job_id)
);
create index if not exists ix_scrape_run_started on silver.fact_scrape_run (started_at desc);

create table if not exists silver.dim_sample_point (
    sample_point_id bigint primary key,
    city_slug       text,
    pincode         text,
    latitude        double precision,
    longitude       double precision,
    loaded_at       timestamptz not null default now()
);

create table if not exists silver.fact_serviceability (
    source_type       text not null check (source_type in ('check_point', 'coverage', 'fulfilment_probe')),
    source_record_id  bigint not null,
    platform          text,
    run_id            bigint,
    sample_point_id   bigint,
    source_store_id   bigint,
    store_key         integer,
    city_slug         text,
    latitude          double precision,
    longitude         double precision,
    is_serviceable    boolean,
    probe_status      text,
    location_verified boolean,
    observed_at       timestamptz,
    obs_date          date generated always as (((observed_at at time zone 'Asia/Kolkata'))::date) stored,
    dq_status         text not null check (dq_status in ('valid', 'suspect', 'invalid')),
    dq_flags          text[] not null default '{}',
    loaded_at         timestamptz not null default now(),
    primary key (source_type, source_record_id)
);
create index if not exists ix_serviceability_date on silver.fact_serviceability (obs_date, platform, city_slug);

create table if not exists silver.dim_listing (
    listing_id          bigint primary key,
    catalog_product_id  bigint,
    platform            text,
    external_id         text,
    url                 text,
    name                text,
    brand               text,
    pack_size           text,
    categories          jsonb,
    list_price          numeric(12,2),
    list_mrp            numeric(12,2),
    created_at          timestamptz,
    brand_id            text,
    variant_id          text,
    category            text,
    subcategory         text,
    l3_category_ids     jsonb,
    loaded_at           timestamptz not null default now()
);

create table if not exists silver.dim_catalog_product (
    catalog_product_id bigint primary key,
    org_id             text,
    name               text,
    brand              text,
    name_source        text,
    loaded_at          timestamptz not null default now()
);

alter table silver.dim_product add column if not exists source_product_id bigint;

insert into silver.sidnl_config (key, value_num, description) values
    ('context_lookback_rows', 5000, 'silver.refresh_scrape_context: re-read this many newest bronze ids per append-only table (late status updates)')
on conflict (key) do nothing;

-- ------------------------------------------------------------------------------------------------ loader
CREATE OR REPLACE FUNCTION silver.refresh_scrape_context()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare
    v_run bigint; v_out jsonb := '{}'::jsonb; v_failed jsonb := '[]'::jsonb; n bigint; v_lo bigint;
    v_lb bigint := coalesce(silver.cfg('context_lookback_rows'), 5000)::bigint;
    v_sec text;
begin
    if not pg_try_advisory_xact_lock(727102) then
        return jsonb_build_object('status', 'skipped', 'reason', 'another refresh_scrape_context is running');
    end if;
    insert into ops.etl_run (brand_key) values ('_context') returning run_id into v_run;

    foreach v_sec in array array['sample_points', 'listings', 'catalog_products', 'product_source_ids', 'shelf_snapshots',
                                 'scrape_runs', 'check_points', 'coverage', 'fulfilment_probes'] loop
        begin
            if v_sec = 'sample_points' then
                insert into silver.dim_sample_point as t (sample_point_id, city_slug, pincode, latitude, longitude)
                select s.id, s.city_slug, nullif(btrim(s.pincode::text), ''), s.lat::double precision, s.lon::double precision
                  from public.sample_points s
                on conflict (sample_point_id) do update set (city_slug, pincode, latitude, longitude, loaded_at)
                    = (excluded.city_slug, excluded.pincode, excluded.latitude, excluded.longitude, now())
                 where (t.city_slug, t.pincode, t.latitude, t.longitude)
                       is distinct from (excluded.city_slug, excluded.pincode, excluded.latitude, excluded.longitude);

            elsif v_sec = 'listings' then
                insert into silver.dim_listing as t (listing_id, catalog_product_id, platform, external_id, url, name, brand,
                       pack_size, categories, list_price, list_mrp, created_at, brand_id, variant_id, category, subcategory,
                       l3_category_ids)
                select l.id, l.product_id, l.platform, l.external_id, l.url, l.name, l.brand, l.pack_size,
                       to_jsonb(l.categories), round(l.price::numeric, 2), round(l.mrp::numeric, 2), l.created_at,
                       l.details::jsonb ->> 'brand_id', l.details::jsonb ->> 'variant_id',
                       l.details::jsonb ->> 'category', l.details::jsonb ->> 'subcategory',
                       l.details::jsonb -> 'l3_category_ids'
                  from public.platform_listings l
                on conflict (listing_id) do update set
                    (catalog_product_id, platform, external_id, url, name, brand, pack_size, categories, list_price, list_mrp,
                     created_at, brand_id, variant_id, category, subcategory, l3_category_ids, loaded_at)
                  = (excluded.catalog_product_id, excluded.platform, excluded.external_id, excluded.url, excluded.name,
                     excluded.brand, excluded.pack_size, excluded.categories, excluded.list_price, excluded.list_mrp,
                     excluded.created_at, excluded.brand_id, excluded.variant_id, excluded.category, excluded.subcategory,
                     excluded.l3_category_ids, now())
                 where (t.catalog_product_id, t.platform, t.external_id, t.url, t.name, t.brand, t.pack_size, t.categories,
                        t.list_price, t.list_mrp, t.created_at, t.brand_id, t.variant_id, t.category, t.subcategory,
                        t.l3_category_ids)
                       is distinct from
                       (excluded.catalog_product_id, excluded.platform, excluded.external_id, excluded.url, excluded.name,
                        excluded.brand, excluded.pack_size, excluded.categories, excluded.list_price, excluded.list_mrp,
                        excluded.created_at, excluded.brand_id, excluded.variant_id, excluded.category, excluded.subcategory,
                        excluded.l3_category_ids);

            elsif v_sec = 'catalog_products' then
                insert into silver.dim_catalog_product as t (catalog_product_id, org_id, name, brand, name_source)
                select p.id, p.org_id::text, p.name, p.brand, p.name_source::text from public.products p
                on conflict (catalog_product_id) do update set (org_id, name, brand, name_source, loaded_at)
                    = (excluded.org_id, excluded.name, excluded.brand, excluded.name_source, now())
                 where (t.org_id, t.name, t.brand, t.name_source)
                       is distinct from (excluded.org_id, excluded.name, excluded.brand, excluded.name_source);

            elsif v_sec = 'product_source_ids' then
                update silver.dim_product d set source_product_id = pp.id
                  from public.platform_products pp
                 where pp.platform = d.platform and pp.external_id = d.platform_product_id
                   and d.source_product_id is distinct from pp.id;

            elsif v_sec = 'shelf_snapshots' then
                select coalesce(max(snapshot_id), 0) - v_lb into v_lo from silver.fact_shelf_snapshot;
                insert into silver.fact_shelf_snapshot as t (snapshot_id, sweep_id, platform, l1_id, l2_id, category_name,
                       source_store_id, store_key, city_slug, latitude, longitude, read_status, read_error, cards_seen,
                       total_items, is_complete, observed_at)
                select sn.id, sn.sweep_id, sn.platform, sn.l1_id::text, sn.l2_id::text, sn.category_name, sn.store_id,
                       ds.store_key, coalesce(ds.city_slug, sn.city_slug), sn.lat::double precision, sn.lon::double precision,
                       sn.status::text, nullif(left(sn.error::text, 1000), ''), silver.safe_int(sn.cards_seen::text),
                       silver.safe_int(sn.total_items::text), sn.complete::boolean, sn.taken_at
                  from public.shelf_snapshots sn
                  left join silver.dim_store ds on ds.source_store_id = sn.store_id
                 where sn.id > greatest(v_lo, 0)
                on conflict (snapshot_id) do update set
                    (sweep_id, store_key, city_slug, latitude, longitude, read_status, read_error, cards_seen, total_items,
                     is_complete, observed_at, loaded_at)
                  = (excluded.sweep_id, excluded.store_key, excluded.city_slug, excluded.latitude, excluded.longitude,
                     excluded.read_status, excluded.read_error, excluded.cards_seen, excluded.total_items,
                     excluded.is_complete, excluded.observed_at, now())
                 where (t.sweep_id, t.store_key, t.city_slug, t.latitude, t.longitude, t.read_status, t.read_error,
                        t.cards_seen, t.total_items, t.is_complete, t.observed_at)
                       is distinct from
                       (excluded.sweep_id, excluded.store_key, excluded.city_slug, excluded.latitude, excluded.longitude,
                        excluded.read_status, excluded.read_error, excluded.cards_seen, excluded.total_items,
                        excluded.is_complete, excluded.observed_at);

            elsif v_sec = 'scrape_runs' then
                with src as (
                    select 'category_sweep'::text as job_type, j.id::bigint as job_id, null::text as org_id, j.platform::text as platform,
                           null::bigint as listing_id, j.l1_id::text as l1_id, j.l2_id::text as l2_id, j.category_name::text as category_name,
                           null::text as query, null::jsonb as brands, null::text as scope, null::text as city_slug,
                           to_jsonb(j.cities) as cities, j.trigger::text as trigger, j.status::text as status,
                           silver.safe_int(j.stores_planned::text) as stores_planned, silver.safe_int(j.stores_done::text) as stores_done,
                           silver.safe_int(j.stores_failed::text) as stores_failed, silver.safe_int(j.stores_skipped::text) as stores_skipped,
                           null::int as points_planned, null::int as points_done, null::int as stores_seen, null::int as blocked,
                           null::int as errors, silver.safe_int(j.requests::text) as requests, null::int as products_found,
                           j.started_at::timestamptz as started_at, j.finished_at::timestamptz as finished_at,
                           nullif(left(j.error::text, 1000), '') as error
                      from public.category_sweeps j
                    union all
                    select 'brand_scrape', j.id, j.org_id::text, j.platform::text, null, null, null, null, j.query::text,
                           to_jsonb(j.brands), j.scope::text, j.city_slug::text, null, null, j.status::text,
                           silver.safe_int(j.stores_planned::text), silver.safe_int(j.stores_done::text),
                           silver.safe_int(j.stores_failed::text), null, null, null, null, null, null,
                           silver.safe_int(j.requests::text), silver.safe_int(j.products_found::text),
                           j.started_at::timestamptz, j.finished_at::timestamptz, nullif(left(j.error::text, 1000), '')
                      from public.brand_scrapes j
                    union all
                    select 'check_run', j.id, j.org_id::text, j.platform::text, j.listing_id, null, null, null, null, null, null,
                           j.city_slug::text, null, null, j.status::text, null, null, null, null,
                           silver.safe_int(j.points_planned::text), silver.safe_int(j.points_done::text),
                           silver.safe_int(j.stores_seen::text), silver.safe_int(j.blocked::text), silver.safe_int(j.errors::text),
                           null, null, j.started_at, j.finished_at, null     -- check_runs.error text stays in bronze
                      from public.check_runs j
                    union all
                    select 'product_lookup', j.id, j.org_id::text, j.platform::text, j.listing_id, null, null, null, null, null, null,
                           j.city_slug::text, null, null, j.status::text,
                           silver.safe_int(j.stores_planned::text), silver.safe_int(j.stores_done::text),
                           silver.safe_int(j.stores_failed::text), null, null, null, null, null, null, null, null,
                           j.started_at::timestamptz, j.finished_at::timestamptz, null                -- product_lookups.error stays in bronze
                      from public.product_lookups j)
                insert into silver.fact_scrape_run as t (job_type, job_id, org_id, platform, listing_id, l1_id, l2_id,
                       category_name, query, brands, scope, city_slug, cities, trigger, status, stores_planned, stores_done,
                       stores_failed, stores_skipped, points_planned, points_done, stores_seen, blocked, errors, requests,
                       products_found, started_at, finished_at, error)
                select * from src
                on conflict (job_type, job_id) do update set
                    (org_id, platform, listing_id, l1_id, l2_id, category_name, query, brands, scope, city_slug, cities,
                     trigger, status, stores_planned, stores_done, stores_failed, stores_skipped, points_planned,
                     points_done, stores_seen, blocked, errors, requests, products_found, started_at, finished_at, error,
                     loaded_at)
                  = (excluded.org_id, excluded.platform, excluded.listing_id, excluded.l1_id, excluded.l2_id,
                     excluded.category_name, excluded.query, excluded.brands, excluded.scope, excluded.city_slug,
                     excluded.cities, excluded.trigger, excluded.status, excluded.stores_planned, excluded.stores_done,
                     excluded.stores_failed, excluded.stores_skipped, excluded.points_planned, excluded.points_done,
                     excluded.stores_seen, excluded.blocked, excluded.errors, excluded.requests, excluded.products_found,
                     excluded.started_at, excluded.finished_at, excluded.error, now())
                 where (t.status, t.stores_planned, t.stores_done, t.stores_failed, t.stores_skipped, t.points_planned,
                        t.points_done, t.stores_seen, t.blocked, t.errors, t.requests, t.products_found, t.started_at,
                        t.finished_at, t.error, t.cities, t.brands)
                       is distinct from
                       (excluded.status, excluded.stores_planned, excluded.stores_done, excluded.stores_failed,
                        excluded.stores_skipped, excluded.points_planned, excluded.points_done, excluded.stores_seen,
                        excluded.blocked, excluded.errors, excluded.requests, excluded.products_found, excluded.started_at,
                        excluded.finished_at, excluded.error, excluded.cities, excluded.brands);

            elsif v_sec = 'check_points' then
                select coalesce(max(source_record_id) filter (where source_type = 'check_point'), 0) - v_lb into v_lo
                  from silver.fact_serviceability;
                insert into silver.fact_serviceability as t (source_type, source_record_id, platform, run_id, sample_point_id,
                       source_store_id, store_key, city_slug, latitude, longitude, is_serviceable, observed_at, dq_status, dq_flags)
                select 'check_point', cp.id, cr.platform::text, cp.run_id, cp.sample_point_id, cp.store_id, ds.store_key,
                       coalesce(sp.city_slug, cr.city_slug::text), sp.lat::double precision, sp.lon::double precision,
                       cp.serviceable::boolean, coalesce(cr.finished_at, cr.started_at)::timestamptz,
                       silver.dq_status(f.flags), f.flags
                  from public.check_points cp
                  left join public.check_runs cr    on cr.id = cp.run_id
                  left join public.sample_points sp on sp.id = cp.sample_point_id
                  left join silver.dim_store ds     on ds.source_store_id = cp.store_id
                 cross join lateral (select array_remove(array[
                        case when cp.serviceable is null then 'no_serviceable_flag' end,
                        case when cr.id is null then 'no_run' end,
                        case when sp.id is null then 'no_sample_point' end], null) as flags) f
                 where cp.id > greatest(v_lo, 0)
                on conflict (source_type, source_record_id) do update set
                    (platform, run_id, sample_point_id, source_store_id, store_key, city_slug, latitude, longitude,
                     is_serviceable, observed_at, dq_status, dq_flags, loaded_at)
                  = (excluded.platform, excluded.run_id, excluded.sample_point_id, excluded.source_store_id,
                     excluded.store_key, excluded.city_slug, excluded.latitude, excluded.longitude, excluded.is_serviceable,
                     excluded.observed_at, excluded.dq_status, excluded.dq_flags, now())
                 where (t.store_key, t.city_slug, t.is_serviceable, t.observed_at, t.dq_flags)
                       is distinct from (excluded.store_key, excluded.city_slug, excluded.is_serviceable,
                                         excluded.observed_at, excluded.dq_flags);

            elsif v_sec = 'coverage' then
                insert into silver.fact_serviceability as t (source_type, source_record_id, platform, sample_point_id,
                       source_store_id, store_key, city_slug, latitude, longitude, is_serviceable, observed_at, dq_status, dq_flags)
                select 'coverage', c.id, c.platform::text, c.sample_point_id, c.store_id, ds.store_key, sp.city_slug,
                       sp.lat::double precision, sp.lon::double precision, c.serviceable::boolean, c.resolved_at::timestamptz,
                       silver.dq_status(f.flags), f.flags
                  from public.coverage c
                  left join public.sample_points sp on sp.id = c.sample_point_id
                  left join silver.dim_store ds     on ds.source_store_id = c.store_id
                 cross join lateral (select array_remove(array[
                        case when c.serviceable is null then 'no_serviceable_flag' end,
                        case when sp.id is null then 'no_sample_point' end], null) as flags) f
                on conflict (source_type, source_record_id) do update set
                    (platform, sample_point_id, source_store_id, store_key, city_slug, latitude, longitude, is_serviceable,
                     observed_at, dq_status, dq_flags, loaded_at)
                  = (excluded.platform, excluded.sample_point_id, excluded.source_store_id, excluded.store_key,
                     excluded.city_slug, excluded.latitude, excluded.longitude, excluded.is_serviceable,
                     excluded.observed_at, excluded.dq_status, excluded.dq_flags, now())
                 where (t.store_key, t.city_slug, t.is_serviceable, t.observed_at, t.dq_flags)
                       is distinct from (excluded.store_key, excluded.city_slug, excluded.is_serviceable,
                                         excluded.observed_at, excluded.dq_flags);

            elsif v_sec = 'fulfilment_probes' then
                select coalesce(max(source_record_id) filter (where source_type = 'fulfilment_probe'), 0) - v_lb into v_lo
                  from silver.fact_serviceability;
                insert into silver.fact_serviceability as t (source_type, source_record_id, platform, city_slug, latitude,
                       longitude, is_serviceable, probe_status, location_verified, observed_at, dq_status, dq_flags)
                select 'fulfilment_probe', p.id, p.platform::text, p.city_slug::text, p.lat::double precision,
                       p.lon::double precision, p.serviceable::boolean, p.status::text, p.location_verified::boolean,
                       p.captured_at::timestamptz, silver.dq_status(f.flags), f.flags
                  from public.fulfilment_probes p
                 cross join lateral (select array_remove(array[
                        case when p.serviceable is null then 'no_serviceable_flag' end,
                        -- the page did not use our location: the answer is about some other place
                        case when p.location_verified is false then 'location_not_verified' end], null) as flags) f
                 where p.id > greatest(v_lo, 0)
                on conflict (source_type, source_record_id) do update set
                    (platform, city_slug, latitude, longitude, is_serviceable, probe_status, location_verified, observed_at,
                     dq_status, dq_flags, loaded_at)
                  = (excluded.platform, excluded.city_slug, excluded.latitude, excluded.longitude, excluded.is_serviceable,
                     excluded.probe_status, excluded.location_verified, excluded.observed_at, excluded.dq_status,
                     excluded.dq_flags, now())
                 where (t.is_serviceable, t.probe_status, t.location_verified, t.observed_at, t.dq_flags)
                       is distinct from (excluded.is_serviceable, excluded.probe_status, excluded.location_verified,
                                         excluded.observed_at, excluded.dq_flags);
            end if;
            get diagnostics n = row_count;
            v_out := v_out || jsonb_build_object(v_sec, n);
        exception when others then
            v_failed := v_failed || jsonb_build_object('section', v_sec, 'sqlstate', sqlstate, 'error', left(sqlerrm, 500),
                                                       'class', silver.classify_error(sqlstate));
        end;
    end loop;

    update ops.etl_run
       set finished_at = now(),
           status = case when jsonb_array_length(v_failed) = 0 then 'success' else 'failed' end,
           stats = v_out || jsonb_build_object('failed_sections', v_failed),
           error = case when jsonb_array_length(v_failed) > 0 then left(v_failed::text, 1000) end
     where run_id = v_run;
    return v_out || jsonb_build_object('run_id', v_run, 'failed_sections', v_failed,
                                       'status', case when jsonb_array_length(v_failed) = 0 then 'success' else 'partial' end);
end $function$
;

-- silver.dq_status already understands no flags; give it the serviceability flags too (all others unchanged)
CREATE OR REPLACE FUNCTION silver.dq_status(p_flags text[])
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
    select case
        when p_flags && array['no_product','no_store','bad_timestamp','unknown_state',
                              'negative_inventory','negative_price','read_failed','no_serviceable_flag'] then 'invalid'
        when p_flags && array['sp_gt_mrp','mrp_missing','oos_with_inventory',
                              'price_missing_in_stock','read_incomplete','location_not_verified'] then 'suspect'
        else 'valid' end
$function$
;

comment on table silver.fact_shelf_snapshot is 'One row per bronze shelf read (public.shelf_snapshots), every status. read_ok = status ok and not incomplete; a read that is not read_ok never counts as out of stock (silver_069/070).';
comment on table silver.fact_scrape_run is 'Run records of the four scrape job tables in one shape (job_type). blocked / errors / stores_failed feed the collection rules; replaces analytics.scraping_jobs as silver''s run table.';
comment on table silver.fact_serviceability is 'Which location is delivered by which store: check_points (per check run), coverage (latest per point x store), fulfilment_probes (page probes; location_verified=false is suspect). Source of not_serviceable, which is never out of stock.';
comment on table silver.dim_sample_point is 'Probe locations (public.sample_points).';
comment on table silver.dim_listing is 'Tracked products (public.platform_listings) incl. details.brand_id / variant_id / category / subcategory / l3_category_ids. meta_* fetch columns and the rest of details stay in bronze.';
comment on table silver.dim_catalog_product is 'public.products: which organisation (org_id) tracks which product, so each brand sees only its own. image_url stays in bronze (dim_product has it).';
comment on column silver.dim_product.source_product_id is 'public.platform_products.id (traceability)';
comment on function silver.refresh_scrape_context() is 'Loads fact_shelf_snapshot, fact_scrape_run, fact_serviceability, dim_sample_point, dim_listing, dim_catalog_product, dim_product.source_product_id. Each section isolated; result in ops.etl_run (brand_key _context). Lock 727102.';
