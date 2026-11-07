-- =============================================================================
-- File:    silver/025_incremental_automation.sql
-- Purpose: make the automatic pipeline cheap on "n" rows and hands-off.
--
--   1. Incremental parser: refresh_brand(brand, p_full) only reads bronze rows newer than the
--      watermark (minus a small look-back); a forced / daily run re-reads everything.
--   2. brand_string_registry: distinct raw brand strings, maintained incrementally, so brand
--      matching runs over a few hundred strings instead of every shelf row (was the 89 s cost).
--   3. register_platforms(): a platform that appears in bronze (flipkart_minutes, amazon_now,
--      bigbasket, ...) is added to dim_platform automatically. Existing rows (incl. the team's
--      demo platform) are never modified.
--   4. onboard_brands(): brands the team added to public.company_brands enter silver.brand_scope
--      automatically, but only once their name is actually seen in captured bronze data.
--   5. quality_checks() + v_match_health: parser/matcher self-tests and map invariants.
--
-- No data is inserted here except what is derived from your own bronze/company tables at run time.
-- Idempotent.
-- =============================================================================

-- vocabulary hygiene: keep only words from config/matching.yaml
delete from silver.ref_noise_word where word in ('the', 'by', 'gm', 'gms', 'kg');

insert into silver.sidnl_config (key, value_num, description) values
    ('incremental_lookback_rows', 5000, 'Incremental parser re-reads this many ids before the watermark (late-committed rows)')
on conflict (key) do nothing;
update silver.sidnl_config set value_num = 120,
       description = 'run_pipeline() will not start again sooner than this after the previous run (incremental loads are cheap)'
 where key = 'pipeline_min_interval_seconds';

-- ---------------------------------------------------------------------------
-- brand string registry
-- ---------------------------------------------------------------------------
alter table silver.pipeline_source add column if not exists registry_last_id bigint not null default 0;

create table if not exists silver.brand_string_registry (
    raw_brand     text primary key,
    first_seen_at timestamptz not null default now()
);
comment on table silver.brand_string_registry is 'Every distinct raw brand string seen in bronze. Lets brand matching run on strings, not rows.';

create or replace function silver.refresh_brand_strings(p_full boolean default false)
returns int language plpgsql set search_path = silver, public, pg_temp as $$
declare s record; v_max bigint; v_n int := 0; v_c int;
begin
    for s in select * from silver.pipeline_source
              where source_schema = 'public' and source_table in ('search_cards', 'shelf_positions', 'platform_listings') loop
        execute format('select coalesce(max(%I), 0) from %I.%I', s.id_column, s.source_schema, s.source_table) into v_max;
        if p_full or v_max > s.registry_last_id then
            execute format(
                'insert into silver.brand_string_registry (raw_brand) '
                'select distinct brand::text from %I.%I where %I > $1 and %I <= $2 and brand is not null '
                'on conflict do nothing',
                s.source_schema, s.source_table, s.id_column, s.id_column)
              using case when p_full then 0 else s.registry_last_id end, v_max;
            get diagnostics v_c = row_count;
            v_n := v_n + v_c;
            update silver.pipeline_source set registry_last_id = v_max
             where source_schema = s.source_schema and source_table = s.source_table;
        end if;
    end loop;
    insert into silver.brand_string_registry (raw_brand)
    select distinct brand::text from public.products where brand is not null
    on conflict do nothing;
    get diagnostics v_c = row_count;
    return v_n + v_c;
end $$;

-- ---------------------------------------------------------------------------
-- automatic platform registration (never touches existing rows)
-- ---------------------------------------------------------------------------
create or replace function silver.register_platforms()
returns text[] language plpgsql set search_path = silver, public, pg_temp as $$
declare v text[];
begin
    with found as (
        select lower(btrim(platform::text)) p from public.shelf_snapshots  where platform is not null
        union select lower(btrim(platform::text)) from public.search_snapshots where platform is not null
        union select lower(btrim(platform::text)) from public.platform_listings where platform is not null
        union select lower(btrim(platform::text)) from public.stores            where platform is not null),
    ins as (
        insert into silver.dim_platform (platform, platform_name, is_test)
        select f.p, initcap(replace(f.p, '_', ' ')), false
        from found f
        where f.p ~ '^[a-z0-9_]+$'
          and not exists (select 1 from silver.dim_platform d where d.platform = f.p)
        returning platform)
    select coalesce(array_agg(platform), '{}') into v from ins;
    return v;
end $$;
comment on function silver.register_platforms() is 'Adds platforms found in bronze to dim_platform (is_test=false). Existing rows, e.g. the team''s demo platform, are untouched.';

-- ---------------------------------------------------------------------------
-- automatic brand onboarding: company_brands -> brand_scope, only with evidence in captured data
-- ---------------------------------------------------------------------------
create or replace function silver.onboard_brands()
returns text[] language plpgsql set search_path = silver, public, pg_temp as $$
declare v text[];
begin
    with cand as (
        select distinct on (silver.norm_key(cb.brand))
               silver.norm_key(cb.brand) as brand_key, cb.brand::text as brand_name, co.name::text as company_name
        from public.company_brands cb
        join public.companies co on co.id = cb.company_id
        where silver.norm_key(cb.brand) is not null
        order by silver.norm_key(cb.brand), cb.id),
    ins as (
        insert into silver.brand_scope (brand_key, brand_name, company_name, raw_brand_aliases)
        select c.brand_key, c.brand_name, c.company_name, array[c.brand_name]
        from cand c
        where not exists (select 1 from silver.brand_scope s where s.brand_key = c.brand_key)
          and exists (select 1 from silver.brand_string_registry r
                      where replace(silver.norm_key(r.raw_brand), ' ', '') = replace(c.brand_key, ' ', ''))
        on conflict (brand_key) do nothing
        returning brand_key)
    select coalesce(array_agg(brand_key), '{}') into v from ins;
    return v;
end $$;
comment on function silver.onboard_brands() is 'company_brands -> brand_scope, once the brand name is seen in bronze. Add extra spellings to brand_scope.raw_brand_aliases.';

-- ---------------------------------------------------------------------------
-- incremental parser
-- ---------------------------------------------------------------------------
drop function if exists silver.refresh_brand(text);

create or replace function silver.refresh_brand(p_brand_key text default 'mr munchies', p_full boolean default false)
returns jsonb
language plpgsql
set search_path to 'silver', 'public', 'pg_temp'
as $function$
declare
    v_scope  silver.brand_scope%rowtype;
    v_run    bigint;
    v_stats  jsonb := '{}'::jsonb;
    v_ins    int;
    v_upd    int;
    v_full   boolean;
    v_lb     bigint := coalesce(silver.cfg('incremental_lookback_rows'), 5000)::bigint;
    w_obs bigint := 0; w_sc bigint := 0; w_sp bigint := 0; w_ssn bigint := 0;
begin
    select * into v_scope from silver.brand_scope where brand_key = p_brand_key;
    if not found then
        raise exception 'unknown brand_key "%": add it to silver.brand_scope first', p_brand_key;
    end if;
    if not v_scope.is_enabled then
        raise exception 'brand "%" is disabled in silver.brand_scope', p_brand_key;
    end if;

    -- a brand never loaded before is always loaded in full
    v_full := p_full or not exists (select 1 from silver.etl_run where brand_key = p_brand_key and status = 'success');
    if not v_full then
        select coalesce(greatest(max(last_seen_id) filter (where source_table = 'observations')     - v_lb, 0), 0),
               coalesce(greatest(max(last_seen_id) filter (where source_table = 'search_cards')      - v_lb, 0), 0),
               coalesce(greatest(max(last_seen_id) filter (where source_table = 'shelf_positions')   - v_lb, 0), 0),
               coalesce(greatest(max(last_seen_id) filter (where source_table = 'search_snapshots')  - v_lb, 0), 0)
          into w_obs, w_sc, w_sp, w_ssn
          from silver.pipeline_source where source_schema = 'public';
    end if;

    insert into silver.etl_run (brand_key) values (p_brand_key) returning run_id into v_run;

    drop table if exists _brand_strings, _listings, _raw, _store_ids, _scans,
                         _cat_src, _cat_best, _prod_src, _prod;

    perform silver.refresh_brand_strings(v_full);

    insert into silver.dim_city (city_slug, city_name, state, center_lat, center_lon)
    select c.slug, c.name, c.state, c.center_lat, c.center_lon from public.cities c
    on conflict (city_slug) do update set
        city_name = excluded.city_name, state = excluded.state,
        center_lat = excluded.center_lat, center_lon = excluded.center_lon;

    insert into silver.dim_brand (brand_key, brand_name, company_name, is_tracked)
    values (v_scope.brand_key, v_scope.brand_name, v_scope.company_name, true)
    on conflict (brand_key) do update set
        brand_name = excluded.brand_name, company_name = excluded.company_name;

    -- brand matching on distinct strings only (a few hundred), never on bronze rows
    create temp table _brand_strings on commit drop as
    select raw_brand as b from silver.brand_string_registry
    where silver.brand_matches(p_brand_key, raw_brand);

    create temp table _listings on commit drop as
    select pl.id                                   as listing_id,
           pl.platform,
           pl.external_id,
           coalesce(pl.name, p.name)               as name,
           coalesce(pl.brand, p.brand)             as brand,
           pl.pack_size,
           coalesce(pl.image_url, p.image_url)     as image_url,
           pl.url,
           pl.product_id                           as catalog_product_id,
           pl.categories::jsonb                    as categories
    from public.platform_listings pl
    join public.products p on p.id = pl.product_id
    where coalesce(pl.brand, p.brand) in (select b from _brand_strings)
      and pl.platform in (select platform from silver.dim_platform where not is_test);

    create temp table _scans on commit drop as
    select ss.*
    from public.search_snapshots ss
    join public.brand_scrapes bs on bs.id = ss.scrape_id
    where ss.id > w_ssn
      and ss.platform in (select platform from silver.dim_platform where not is_test)
      and exists (select 1
                  from json_array_elements_text(
                           case when json_typeof(bs.brands) = 'array' then bs.brands else '[]'::json end) x(v)
                  where silver.brand_matches(p_brand_key, x.v));

    create temp table _raw on commit drop as
    select 'stock_check'::text            as source_type,
           'public.observations'::text    as source_table,
           o.id                           as source_record_id,
           l.platform,
           l.external_id                  as platform_product_id,
           o.store_id                     as src_store_id,
           null::int                      as planned_store_id,
           ('stock_check:' || o.run_id)   as job_ref,
           o.run_id::int                  as run_id,
           null::int                      as scrape_id,
           null::bigint                   as snapshot_id,
           l.listing_id                   as listing_id,
           o.observed_at,
           o.state,
           o.inventory,
           o.inventory_capped,
           o.price::numeric               as price,
           o.mrp::numeric                 as mrp,
           null::int                      as pos,
           null::int                      as opos,
           null::boolean                  as is_ad,
           null::text                     as ad_type,
           null::text                     as ptype,
           null::text                     as name,
           null::text                     as brand,
           null::text                     as pack,
           null::text                     as image_url
    from public.observations o
    join _listings l on l.listing_id = o.listing_id
    where o.id > w_obs

    union all
    select 'brand_search', 'public.search_cards', c.id,
           ss.platform, c.external_id,
           coalesce(c.store_id, ss.store_id, ss.planned_store_id),
           ss.planned_store_id,
           ('brand_scrape:' || ss.scrape_id),
           null::int, ss.scrape_id::int, ss.id::bigint, null::int,
           ss.taken_at, c.state, c.inventory, c.inventory_capped,
           c.price::numeric, c.mrp::numeric,
           c."position", c.organic_position, c.is_ad, null::text,
           c.ptype, c.name, c.brand, c.pack, c.image_url
    from public.search_cards c
    join public.search_snapshots ss on ss.id = c.snapshot_id
    where c.id > w_sc
      and c.brand in (select b from _brand_strings)
      and ss.platform in (select platform from silver.dim_platform where not is_test)

    union all
    select 'category_shelf', 'public.shelf_positions', sp.id,
           sn.platform, sp.external_id,
           coalesce(sp.store_id, sn.store_id),
           sn.store_id,
           case when sn.sweep_id is not null then 'category_sweep:' || sn.sweep_id
                else 'shelf_snapshot:' || sn.id end,
           null::int, null::int, sn.id::bigint, null::int,
           sn.taken_at, sp.state, sp.inventory, sp.inventory_capped,
           sp.price::numeric, sp.mrp::numeric,
           sp."position", sp.organic_position, sp.is_ad, sp.ad_type,
           sp.ptype, sp.name, sp.brand, sp.pack, sp.image_url
    from public.shelf_positions sp
    join public.shelf_snapshots sn on sn.id = sp.snapshot_id
    where sp.id > w_sp
      and sp.brand in (select b from _brand_strings)
      and sn.platform in (select platform from silver.dim_platform where not is_test);

    create temp table _store_ids on commit drop as
    select src_store_id as id from _raw where src_store_id is not null
    union select planned_store_id from _raw where planned_store_id is not null
    union select store_id from _scans where store_id is not null
    union select planned_store_id from _scans where planned_store_id is not null;

    with ins as (
        insert into silver.dim_store (platform, store_external_id, source_store_id, store_name,
                                      city_slug, latitude, longitude, first_seen_at, last_seen_at)
        select s.platform, s.external_id, s.id, s.name, s.city_slug, s.lat, s.lon,
               s.first_seen_at, s.last_seen_at
        from public.stores s
        where s.id in (select id from _store_ids)
          and s.platform in (select platform from silver.dim_platform)
        on conflict (source_store_id) do update set
            store_name = excluded.store_name, city_slug = excluded.city_slug,
            latitude = excluded.latitude, longitude = excluded.longitude,
            first_seen_at = excluded.first_seen_at, last_seen_at = excluded.last_seen_at
        returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;
    v_stats := v_stats || jsonb_build_object('dim_store', jsonb_build_object('inserted', v_ins, 'updated', v_upd));

    create temp table _cat_src on commit drop as
    select l.platform, l.external_id as platform_product_id, 1 as prio,
           l.categories -> 0 ->> 'id'   as l1_id, l.categories -> 0 ->> 'name' as l1_name,
           l.categories -> 1 ->> 'id'   as l2_id, l.categories -> 1 ->> 'name' as l2_name,
           l.categories -> 2 ->> 'id'   as l3_id, l.categories -> 2 ->> 'name' as l3_name
    from _listings l
    where jsonb_typeof(l.categories) = 'array' and jsonb_array_length(l.categories) >= 1
    union all
    select pc.platform::text, pc.product_id::text, 2,
           pc.category_l1_id::text, c.category_l1,
           pc.category_l2_id::text, c.category_l2,
           null, null
    from analytics.product_categories pc
    left join analytics.categories c
           on c.platform = pc.platform
          and c.category_l1_id = pc.category_l1_id
          and c.category_l2_id = pc.category_l2_id
    where (pc.platform::text, pc.product_id::text) in
          (select platform, platform_product_id from _raw);

    create temp table _cat_best on commit drop as
    select distinct on (platform, platform_product_id)
           platform, platform_product_id, l1_id, l1_name, l2_id, l2_name, l3_id, l3_name
    from _cat_src
    where l1_name is not null
    order by platform, platform_product_id, prio;

    insert into silver.dim_category (platform, l1_id, l1_name, l2_id, l2_name, l3_id, l3_name)
    select distinct platform, l1_id, l1_name, l2_id, l2_name, l3_id, l3_name from _cat_best
    on conflict do nothing;

    create temp table _prod_src on commit drop as
    select l.platform, l.external_id as pid, 1 as prio, now() as seen_at,
           l.name, l.brand, l.pack_size as pack, null::text as ptype, l.image_url, l.url,
           l.listing_id, l.catalog_product_id
    from _listings l
    union all
    select r.platform, r.platform_product_id, case r.source_type when 'brand_search' then 2 else 3 end,
           r.observed_at, r.name, r.brand, r.pack, r.ptype, r.image_url, null::text, null::int, null::int
    from _raw r where r.source_type <> 'stock_check';

    create temp table _prod on commit drop as
    select platform, pid,
           (array_agg(name       order by prio, seen_at desc) filter (where name is not null))[1]       as name,
           (array_agg(brand      order by prio, seen_at desc) filter (where brand is not null))[1]      as brand,
           (array_agg(pack       order by prio, seen_at desc) filter (where pack is not null))[1]       as pack,
           (array_agg(ptype      order by prio, seen_at desc) filter (where ptype is not null))[1]      as ptype,
           (array_agg(image_url  order by prio, seen_at desc) filter (where image_url is not null))[1]  as image_url,
           (array_agg(url        order by prio, seen_at desc) filter (where url is not null))[1]        as url,
           (array_agg(listing_id order by prio, seen_at desc) filter (where listing_id is not null))[1] as listing_id,
           (array_agg(catalog_product_id order by prio, seen_at desc)
                                                              filter (where catalog_product_id is not null))[1] as catalog_product_id
    from _prod_src
    group by platform, pid;

    with ins as (
        insert into silver.dim_product (platform, platform_product_id, brand_key, product_name, variant,
                                        product_type, pack_raw, size_value, size_unit, pack_count,
                                        category_key, listing_id, catalog_product_id, image_url, product_url)
        select p.platform, p.pid, p_brand_key,
               coalesce(p.name, 'Unknown product ' || p.pid),
               silver.parse_variant(p.name, p.brand, p.ptype),
               p.ptype, p.pack, pk.size_value, pk.size_unit, pk.pack_count,
               dc.category_key, p.listing_id, p.catalog_product_id, p.image_url, p.url
        from _prod p
        cross join lateral silver.parse_pack(p.pack) pk
        left join _cat_best cb on cb.platform = p.platform and cb.platform_product_id = p.pid
        left join silver.dim_category dc
               on dc.platform = cb.platform
              and dc.l1_id   is not distinct from cb.l1_id   and dc.l1_name is not distinct from cb.l1_name
              and dc.l2_id   is not distinct from cb.l2_id   and dc.l2_name is not distinct from cb.l2_name
              and dc.l3_id   is not distinct from cb.l3_id   and dc.l3_name is not distinct from cb.l3_name
        on conflict (platform, platform_product_id) do update set
            brand_key = excluded.brand_key, product_name = excluded.product_name,
            variant = excluded.variant, product_type = coalesce(excluded.product_type, silver.dim_product.product_type),
            pack_raw = excluded.pack_raw, size_value = excluded.size_value, size_unit = excluded.size_unit,
            pack_count = excluded.pack_count,
            category_key = coalesce(excluded.category_key, silver.dim_product.category_key),
            listing_id = coalesce(excluded.listing_id, silver.dim_product.listing_id),
            catalog_product_id = coalesce(excluded.catalog_product_id, silver.dim_product.catalog_product_id),
            image_url = coalesce(excluded.image_url, silver.dim_product.image_url),
            product_url = coalesce(excluded.product_url, silver.dim_product.product_url)
        returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;
    v_stats := v_stats || jsonb_build_object('dim_product', jsonb_build_object('inserted', v_ins, 'updated', v_upd));

    with ins as (
        insert into silver.fact_product_reading (
            source_type, source_table, source_record_id, product_key, store_key, planned_store_key,
            city_slug, job_ref, run_id, scrape_id, snapshot_id, listing_id, observed_at,
            stock_state_raw, stock_status, is_listed, is_available, inventory_units, inventory_is_capped,
            selling_price, mrp, search_position, organic_position, is_ad, ad_type,
            osa_eligible, dq_status, dq_flags, etl_run_id)
        select r.source_type, r.source_table, r.source_record_id, dp.product_key, ds.store_key, dps.store_key,
               ds.city_slug, r.job_ref, r.run_id, r.scrape_id, r.snapshot_id, r.listing_id, r.observed_at,
               r.state, q.status, q.status <> 'not_listed',
               case q.status when 'in_stock' then true when 'out_of_stock' then false end,
               r.inventory, coalesce(r.inventory_capped, false),
               round(r.price, 2), round(r.mrp, 2), r.pos, r.opos, r.is_ad, r.ad_type,
               (r.source_type = 'stock_check' and q.status in ('in_stock', 'out_of_stock')
                                              and silver.dq_status(q.flags) = 'valid'),
               silver.dq_status(q.flags), q.flags, v_run
        from _raw r
        join silver.dim_product dp on dp.platform = r.platform and dp.platform_product_id = r.platform_product_id
        left join silver.dim_store ds  on ds.source_store_id  = r.src_store_id
        left join silver.dim_store dps on dps.source_store_id = r.planned_store_id
        cross join lateral (
            select silver.map_stock_status(r.state) as status,
                   silver.reading_dq(true, ds.store_key is not null, r.observed_at,
                                     silver.map_stock_status(r.state), r.inventory,
                                     round(r.price, 2), round(r.mrp, 2)) as flags) q
        on conflict (source_type, source_record_id) do update set
            product_key = excluded.product_key, store_key = excluded.store_key,
            planned_store_key = excluded.planned_store_key, city_slug = excluded.city_slug,
            job_ref = excluded.job_ref, run_id = excluded.run_id, scrape_id = excluded.scrape_id,
            snapshot_id = excluded.snapshot_id, listing_id = excluded.listing_id,
            observed_at = excluded.observed_at, stock_state_raw = excluded.stock_state_raw,
            stock_status = excluded.stock_status, is_listed = excluded.is_listed,
            is_available = excluded.is_available, inventory_units = excluded.inventory_units,
            inventory_is_capped = excluded.inventory_is_capped, selling_price = excluded.selling_price,
            mrp = excluded.mrp, search_position = excluded.search_position,
            organic_position = excluded.organic_position, is_ad = excluded.is_ad, ad_type = excluded.ad_type,
            osa_eligible = excluded.osa_eligible, dq_status = excluded.dq_status, dq_flags = excluded.dq_flags,
            loaded_at = now(), etl_run_id = excluded.etl_run_id
        returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;
    v_stats := v_stats || jsonb_build_object('fact_product_reading', jsonb_build_object('inserted', v_ins, 'updated', v_upd));

    with ins as (
        insert into silver.fact_store_scan (
            snapshot_id, scrape_id, scrape_query, platform, brand_key, store_key, planned_store_key,
            city_slug, scanned_at, scan_status, pages_read, cards_seen, brand_cards_matched,
            is_complete, stopped_early, is_valid_denominator, dq_flags, etl_run_id)
        select s.id, s.scrape_id, bs.query, s.platform, p_brand_key, ds.store_key, dps.store_key,
               coalesce(ds.city_slug, dps.city_slug), s.taken_at, s.status, s.pages_read, s.cards_seen,
               s.cards_matched, s.complete, s.stopped_early,
               (s.status = 'ok' and ds.store_key is not null),
               array_remove(array[
                   case when ds.store_key is null then 'no_store' end,
                   case when s.status <> 'ok' then 'scan_' || s.status end,
                   case when s.store_id is not null and s.store_id is distinct from s.planned_store_id
                        then 'info_store_differs_from_planned' end], null),
               v_run
        from _scans s
        left join public.brand_scrapes bs on bs.id = s.scrape_id
        left join silver.dim_store ds  on ds.source_store_id  = s.store_id
        left join silver.dim_store dps on dps.source_store_id = s.planned_store_id
        on conflict (snapshot_id) do update set
            scrape_query = excluded.scrape_query, store_key = excluded.store_key,
            planned_store_key = excluded.planned_store_key, city_slug = excluded.city_slug,
            scanned_at = excluded.scanned_at, scan_status = excluded.scan_status,
            pages_read = excluded.pages_read, cards_seen = excluded.cards_seen,
            brand_cards_matched = excluded.brand_cards_matched, is_complete = excluded.is_complete,
            stopped_early = excluded.stopped_early, is_valid_denominator = excluded.is_valid_denominator,
            dq_flags = excluded.dq_flags, loaded_at = now(), etl_run_id = excluded.etl_run_id
        returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;
    v_stats := v_stats || jsonb_build_object('fact_store_scan', jsonb_build_object('inserted', v_ins, 'updated', v_upd));

    -- first/last seen only for products touched by this load
    update silver.dim_product p
       set first_seen_at = x.mn, last_seen_at = x.mx
      from (select f.product_key, min(f.observed_at) mn, max(f.observed_at) mx
              from silver.fact_product_reading f
             where f.product_key in (select dp.product_key
                                       from silver.dim_product dp
                                       join _prod t on t.platform = dp.platform and t.pid = dp.platform_product_id)
             group by f.product_key) x
     where x.product_key = p.product_key
       and (p.first_seen_at, p.last_seen_at) is distinct from (x.mn, x.mx);

    v_stats := v_stats || jsonb_build_object('brand_key', p_brand_key, 'run_id', v_run, 'mode',
                                             case when v_full then 'full' else 'incremental' end);
    if v_full then
        v_stats := v_stats || jsonb_build_object(
            'dq', (select coalesce(jsonb_object_agg(dq_status, n), '{}'::jsonb)
                     from (select f.dq_status, count(*) n
                             from silver.fact_product_reading f
                             join silver.dim_product p using (product_key)
                            where p.brand_key = p_brand_key group by 1) d));
    end if;

    update silver.etl_run set finished_at = now(), status = 'success', stats = v_stats where run_id = v_run;
    return v_stats;
end
$function$;
comment on function silver.refresh_brand(text, boolean) is 'Parser + cleaning for one brand. p_full=false reads only bronze rows newer than the watermark (less a look-back); a brand never loaded before is loaded in full.';

-- ---------------------------------------------------------------------------
-- quality gates and health views
-- ---------------------------------------------------------------------------
create or replace function silver.quality_checks()
returns table (check_name text, ok boolean, detail text)
language plpgsql stable set search_path = silver, public, extensions, pg_temp as $$
declare v_parser text; v_n bigint;
begin
    v_parser := silver.selftest_parser();
    check_name := 'parser_selftest'; ok := v_parser = 'all parser tests passed'; detail := v_parser; return next;

    for check_name, ok, detail in
        select 'matcher_selftest:' || t.test, t.ok, t.detail from silver.selftest_matcher_pure() t loop
        return next;
    end loop;

    select count(*) into v_n from silver.dim_product p
     where not exists (select 1 from silver.product_xref x where x.product_key = p.product_key);
    check_name := 'every_product_has_si_id'; ok := v_n = 0; detail := v_n || ' products without an SI id'; return next;

    select count(*) into v_n from silver.product_xref x join silver.canonical_product c using (sidnl_id) where not c.is_active;
    check_name := 'xref_points_to_active_si_id'; ok := v_n = 0; detail := v_n || ' products mapped to a retired SI id'; return next;

    select count(*) into v_n from (
        select x.sidnl_id, d.platform from silver.product_xref x join silver.dim_product d using (product_key)
        group by 1, 2 having count(*) > 1) z;
    check_name := 'one_product_per_platform_per_si_id'; ok := v_n = 0; detail := v_n || ' SI ids hold two products of one platform'; return next;

    select count(*) into v_n from silver.canonical_product c
     where c.is_active and not exists (select 1 from silver.product_xref x where x.sidnl_id = c.sidnl_id);
    check_name := 'no_empty_si_ids'; ok := v_n = 0; detail := v_n || ' active SI ids without any product'; return next;
end $$;
comment on function silver.quality_checks() is 'Parser/matcher self-tests plus map invariants. Every row must have ok = true.';

create or replace view silver.v_quality_latest with (security_invoker = true) as
select * from silver.quality_checks();

create or replace view silver.v_match_health with (security_invoker = true) as
select x.match_status, x.match_method,
       count(*)                          as products,
       round(avg(x.score), 3)            as avg_score,
       round(min(x.score), 3)            as min_score,
       count(distinct x.sidnl_id)        as si_ids
from silver.product_xref x
group by x.match_status, x.match_method;
comment on view silver.v_match_health is 'How products were mapped: counts and scores per status/method. Watch PENDING_REVIEW and min_score.';

-- ---------------------------------------------------------------------------
-- orchestrator (replaces 023 version): prepares sources, loads, maps, checks, builds gold
-- ---------------------------------------------------------------------------
create or replace function silver.run_pipeline(p_force boolean default false, p_trigger text default 'manual')
returns jsonb
language plpgsql
set search_path to 'silver', 'public', 'extensions', 'pg_temp'
set statement_timeout to '600s'
as $function$
declare
    s record; b record; v_max bigint;
    v_new jsonb := '{}'::jsonb; v_maxes jsonb := '{}'::jsonb; v_steps jsonb := '{}'::jsonb;
    v_unmapped int; v_run bigint; v_failed boolean := false; v_t timestamptz;
    v_min int := coalesce(silver.cfg('pipeline_min_interval_seconds'), 120)::int;
    v_tmp jsonb; v_plat text[]; v_brands text[]; v_full boolean; v_bad jsonb;
begin
    if not pg_try_advisory_xact_lock(727100) then
        return jsonb_build_object('status', 'skipped', 'reason', 'another run is in progress');
    end if;

    for s in select * from silver.pipeline_source loop
        execute format('select coalesce(max(%I), 0) from %I.%I', s.id_column, s.source_schema, s.source_table) into v_max;
        v_maxes := v_maxes || jsonb_build_object(s.source_schema || '.' || s.source_table, v_max);
        if v_max > s.last_seen_id then
            v_new := v_new || jsonb_build_object(s.source_schema || '.' || s.source_table, v_max);
        end if;
    end loop;
    select count(*) into v_unmapped from silver.dim_product p
     where not exists (select 1 from silver.product_xref x where x.product_key = p.product_key);

    if not p_force and v_new = '{}'::jsonb and v_unmapped = 0 then
        return jsonb_build_object('status', 'idle');
    end if;
    if not p_force and exists (select 1 from silver.pipeline_run where started_at > now() - make_interval(secs => v_min)) then
        return jsonb_build_object('status', 'debounced', 'new_data', v_new);
    end if;

    insert into silver.pipeline_run (trigger, new_data) values (p_trigger, v_new) returning run_id into v_run;

    -- 0. discover: new platforms, raw brand strings, brands to onboard
    begin
        v_plat := silver.register_platforms();
        perform silver.refresh_brand_strings(p_force);
        v_brands := silver.onboard_brands();
        v_steps := v_steps || jsonb_build_object('discover', jsonb_build_object(
            'ok', true, 'new_platforms', to_jsonb(v_plat), 'new_brands', to_jsonb(v_brands)));
    exception when others then
        v_failed := true; v_plat := '{}';
        v_steps := v_steps || jsonb_build_object('discover', jsonb_build_object('ok', false, 'error', sqlerrm));
    end;
    -- a platform seen for the first time needs its whole bronze history
    v_full := p_force or coalesce(array_length(v_plat, 1), 0) > 0;

    -- 1. parse + clean, per brand (failures isolated)
    for b in select brand_key from silver.brand_scope where is_enabled order by brand_key loop
        v_t := clock_timestamp();
        begin
            v_tmp := silver.refresh_brand(b.brand_key, v_full);
            v_steps := v_steps || jsonb_build_object('refresh_brand:' || b.brand_key, jsonb_build_object(
                'ok', true, 'seconds', round(extract(epoch from clock_timestamp() - v_t)::numeric, 2), 'stats', v_tmp));
        exception when others then
            v_failed := true;
            v_steps := v_steps || jsonb_build_object('refresh_brand:' || b.brand_key, jsonb_build_object('ok', false, 'error', sqlerrm));
        end;
    end loop;

    v_t := clock_timestamp();
    begin
        perform silver.refresh_category_market();
        v_steps := v_steps || jsonb_build_object('refresh_category_market', jsonb_build_object(
            'ok', true, 'seconds', round(extract(epoch from clock_timestamp() - v_t)::numeric, 2)));
    exception when others then
        v_failed := true;
        v_steps := v_steps || jsonb_build_object('refresh_category_market', jsonb_build_object('ok', false, 'error', sqlerrm));
    end;

    -- 2. lexical + semantic + rules -> canonical map
    begin
        v_steps := v_steps || jsonb_build_object('map_new_products', jsonb_build_object('ok', true, 'result', silver.map_new_products()));
        v_steps := v_steps || jsonb_build_object('sync_canonical_attrs', jsonb_build_object('ok', true, 'updated', silver.sync_canonical_attrs()));
    exception when others then
        v_failed := true;
        v_steps := v_steps || jsonb_build_object('canonical_map', jsonb_build_object('ok', false, 'error', sqlerrm));
    end;

    -- 3. quality gate (recorded; a failed check never blocks the watermark, it is visible in v_quality_latest)
    begin
        select jsonb_agg(jsonb_build_object('check', q.check_name, 'detail', q.detail)) into v_bad
          from silver.quality_checks() q where not q.ok;
        v_steps := v_steps || jsonb_build_object('quality_gate', jsonb_build_object('ok', v_bad is null, 'failed', v_bad));
    exception when others then
        v_steps := v_steps || jsonb_build_object('quality_gate', jsonb_build_object('ok', false, 'error', sqlerrm));
    end;

    -- 4. gold
    if not v_failed then
        v_t := clock_timestamp();
        begin
            perform gold.refresh_all();
            v_steps := v_steps || jsonb_build_object('gold.refresh_all', jsonb_build_object(
                'ok', true, 'seconds', round(extract(epoch from clock_timestamp() - v_t)::numeric, 2)));
        exception when others then
            v_failed := true;
            v_steps := v_steps || jsonb_build_object('gold.refresh_all', jsonb_build_object('ok', false, 'error', sqlerrm));
        end;
    else
        v_steps := v_steps || jsonb_build_object('gold.refresh_all', jsonb_build_object('ok', false, 'skipped', 'silver step failed'));
    end if;

    if not v_failed then
        update silver.pipeline_source ps
           set last_seen_id = (v_maxes ->> (ps.source_schema || '.' || ps.source_table))::bigint
         where v_maxes ? (ps.source_schema || '.' || ps.source_table);
    end if;

    update silver.pipeline_run
       set finished_at = clock_timestamp(), status = case when v_failed then 'partial' else 'success' end, steps = v_steps
     where run_id = v_run;

    return jsonb_build_object('status', case when v_failed then 'partial' else 'success' end,
                              'run_id', v_run, 'mode', case when v_full then 'full' else 'incremental' end,
                              'new_data', v_new, 'steps', v_steps);
end $function$;

-- ---------------------------------------------------------------------------
-- lock-down for the objects above (same as 024)
-- ---------------------------------------------------------------------------
alter table silver.brand_string_registry enable row level security;
do $$
begin
    if exists (select 1 from pg_roles where rolname = 'anon') then
        revoke all on all tables in schema silver from anon;
        revoke all on all functions in schema silver from anon;
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then
        revoke all on all tables in schema silver from authenticated;
        revoke all on all functions in schema silver from authenticated;
    end if;
end $$;
