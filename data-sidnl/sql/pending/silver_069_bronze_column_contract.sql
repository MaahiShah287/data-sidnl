-- silver_069_bronze_column_contract
-- Brings silver in line with "Bronze -> Silver: which columns to carry" (2026-11-10).
--   Added   fact_product_reading: read_status, read_complete (snapshot status / complete), max_allowed_quantity,
--           pack_size_seen, store_role (observations.details), matched_by, variant_of (search_cards)
--   Added   fact_store_scan: search_query, latitude, longitude, scan_error (search_snapshots)
--   Removed fact_store_scan.pages_read            (doc: leave in bronze; nothing reads it)
--           dim_city.center_lat / center_lon       (doc: map display only, carry only if the front end reads them
--                                                   from gold; dash.dim_city and portal/ do not)
--           dim_store."store_weight (...)"         (not a bronze column, never written or read)
--   Fixed   a failed (status <> 'ok') or incomplete (complete = false) read no longer produces out_of_stock rows:
--           the row is kept, out_of_stock becomes 'unknown', flag read_failed (invalid) / read_incomplete (suspect),
--           so dash (dq_status = 'valid' only) never counts it. Knob: sidnl_config.exclude_incomplete_reads (1 = on).
-- Bronze is only read. Existing rows: run `select silver.backfill_read_flags();` once after applying.

-- 0. preflight: every bronze column this migration reads must exist, otherwise stop before changing anything
do $preflight$
declare v_missing text;
begin
    select string_agg(v.t || '.' || v.c, ', ' order by v.t, v.c) into v_missing
      from (values ('observations', 'details'), ('search_cards', 'matched_by'), ('search_cards', 'variant_of'),
                   ('search_snapshots', 'status'), ('search_snapshots', 'complete'), ('search_snapshots', 'query'),
                   ('search_snapshots', 'lat'), ('search_snapshots', 'lon'), ('search_snapshots', 'error'),
                   ('search_snapshots', 'city_slug'), ('shelf_snapshots', 'status'), ('shelf_snapshots', 'complete'))
           v (t, c)
     where not exists (select 1 from information_schema.columns ic
                        where ic.table_schema = 'public' and ic.table_name = v.t and ic.column_name = v.c);
    if v_missing is not null then
        raise exception 'silver_069 preflight: bronze columns not found: %', v_missing;
    end if;
end
$preflight$;

-- 1. helpers
CREATE OR REPLACE FUNCTION silver.safe_int(p_text text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
 SET search_path TO 'silver', 'pg_temp'
AS $function$
    select case when btrim(p_text) ~ '^-?[0-9]{1,9}$' then btrim(p_text)::integer end
$function$
;

CREATE OR REPLACE FUNCTION silver.read_flags(p_read_status text, p_read_complete boolean, p_exclude_incomplete boolean DEFAULT true)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
 SET search_path TO 'silver', 'pg_temp'
AS $function$
    select array_remove(array[
        case when p_read_status is not null and lower(btrim(p_read_status)) <> 'ok' then 'read_failed' end,
        case when p_read_complete is false and coalesce(lower(btrim(p_read_status)), 'ok') = 'ok'
             then case when p_exclude_incomplete then 'read_incomplete' else 'info_read_incomplete' end end
    ], null)
$function$
;

CREATE OR REPLACE FUNCTION silver.read_stock_status(p_status text, p_read_status text, p_read_complete boolean, p_exclude_incomplete boolean DEFAULT true)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
 SET search_path TO 'silver', 'pg_temp'
AS $function$
    select case when p_status = 'out_of_stock'
                 and ((p_read_status is not null and lower(btrim(p_read_status)) <> 'ok')
                      or (p_read_complete is false and p_exclude_incomplete))
                then 'unknown' else p_status end
$function$
;

-- 2. columns
alter table silver.fact_product_reading
    add column if not exists read_status text,
    add column if not exists read_complete boolean,
    add column if not exists max_allowed_quantity integer,
    add column if not exists pack_size_seen text,
    add column if not exists store_role text,
    add column if not exists matched_by text,
    add column if not exists variant_of text;

alter table silver.fact_store_scan
    add column if not exists search_query text,
    add column if not exists latitude double precision,
    add column if not exists longitude double precision,
    add column if not exists scan_error text,
    drop column if exists pages_read;

alter table silver.dim_city
    drop column if exists center_lat,
    drop column if exists center_lon;

alter table silver.dim_store
    drop column if exists "store_weight (weight per store, e.g. store sales)";

insert into silver.sidnl_config (key, value_num, description)
values ('exclude_incomplete_reads', 1,
        '1 = a read with complete=false is flagged read_incomplete (suspect, out of metrics) and never yields out_of_stock; 0 = flag only (info_read_incomplete)')
on conflict (key) do nothing;

-- 3. loaders (exact live text from silver_068 with the changes above)

CREATE OR REPLACE FUNCTION silver.dq_status(p_flags text[])
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
    select case
        when p_flags && array['no_product','no_store','bad_timestamp','unknown_state',
                              'negative_inventory','negative_price','read_failed'] then 'invalid'
        when p_flags && array['sp_gt_mrp','mrp_missing','oos_with_inventory',
                              'price_missing_in_stock','read_incomplete'] then 'suspect'
        else 'valid' end
$function$
;

CREATE OR REPLACE FUNCTION silver.load_category_chunk(p_platform text, p_l1 text, p_l2 text, p_lo bigint, p_hi bigint, p_run bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare v_ins int; v_upd int; v_new_stores int; v_p jsonb;
        v_excl boolean := coalesce(silver.cfg('exclude_incomplete_reads'), 1) = 1;
begin
        with ins as (
            insert into silver.dim_store (platform, store_external_id, source_store_id, store_name, city_slug,
                                          latitude, longitude, first_seen_at, last_seen_at)
            select s.platform, s.external_id, s.id, s.name, s.city_slug, s.lat, s.lon, s.first_seen_at, s.last_seen_at
            from public.stores s
            where s.id in (
                    select distinct coalesce(sp.store_id, sn.store_id)
                    from public.shelf_positions sp
                    join public.shelf_snapshots sn on sn.id = sp.snapshot_id
                    where sp.id > p_lo and sp.id <= p_hi and sn.status = 'ok'
                      and sn.platform = p_platform and sn.l1_id = p_l1 and sn.l2_id = p_l2)
              and s.platform in (select platform from silver.dim_platform)
            on conflict (source_store_id) do nothing
            returning 1)
        select count(*) into v_new_stores from ins;

        with src as materialized (
            select sp.id, sp.snapshot_id, sn.platform, sn.l1_id, sn.l2_id, coalesce(sp.store_id, sn.store_id) as src_store,
                   sn.taken_at, sp."position" as pos, sp.organic_position as opos, sp.is_ad, sp.ad_type, pp.brand,
                   sp.external_id, pp.name, pp.pack, sp.state, sp.inventory, sp.inventory_capped,
                   sp.price::numeric as price, sp.mrp::numeric as mrp,
                   sn.cards_seen, sn.total_items, sn.complete
            from public.shelf_positions sp
            join public.shelf_snapshots sn on sn.id = sp.snapshot_id
            left join public.platform_products pp on pp.platform = sn.platform and pp.external_id = sp.external_id
            join silver.dim_platform dpl on dpl.platform = sn.platform and not dpl.is_test
            where sp.id > p_lo and sp.id <= p_hi and sn.status = 'ok'
              and sn.platform = p_platform and sn.l1_id = p_l1 and sn.l2_id = p_l2
              and not exists (select 1 from ops.dead_letter dl
                               where dl.status = 'open' and dl.source_table = 'public.shelf_positions' and dl.bronze_id = sp.id)
        ), bm as materialized (
            select x.b as raw_brand,
                   (select sb.brand_key from silver.brand_scope sb
                     where sb.is_enabled and silver.brand_matches(sb.brand_key, x.b)
                     order by sb.brand_key limit 1) as client_key
            from (select distinct brand as b from src where brand is not null) x
            offset 0
        ), ins as (
            insert into silver.fact_shelf_position as t (
                source_record_id, snapshot_id, platform, l1_id, l2_id, store_key, city_slug, observed_at, shelf_position,
                organic_position, is_ad, ad_type, brand_raw, brand_key, is_client_brand, platform_product_id, product_name,
                pack_raw, stock_status, inventory_units, inventory_is_capped, selling_price, mrp,
                shelf_cards_seen, shelf_total_items, shelf_complete, dq_status, dq_flags, etl_run_id)
            select s.id, s.snapshot_id, s.platform, s.l1_id, s.l2_id, ds.store_key, ds.city_slug, s.taken_at, s.pos, s.opos,
                   s.is_ad, s.ad_type, s.brand,
                   coalesce(bm.client_key, case when s.brand is null then null else nullif(silver.norm_key(s.brand), '') end, '(unknown)'),
                   bm.client_key is not null,
                   s.external_id, s.name, s.pack,
                   q.status, s.inventory, coalesce(s.inventory_capped, false), round(s.price, 2), round(s.mrp, 2),
                   s.cards_seen, s.total_items, s.complete, silver.dq_status(q.flags), q.flags, p_run
            from src s
            left join bm on bm.raw_brand = s.brand
            left join silver.dim_store ds on ds.source_store_id = s.src_store
            cross join lateral (
                select silver.read_stock_status(silver.map_stock_status(s.state), 'ok', s.complete, v_excl) as st) st0
            cross join lateral (
                -- silver_069: an incomplete shelf read never produces out_of_stock; the row is kept and flagged
                select st0.st as status,
                       silver.reading_dq(true, ds.store_key is not null, s.taken_at, st0.st,
                                         s.inventory, round(s.price, 2), round(s.mrp, 2))
                       || silver.read_flags('ok', s.complete, v_excl) as flags) q
            on conflict (source_record_id) do update set
                snapshot_id = excluded.snapshot_id, store_key = excluded.store_key, city_slug = excluded.city_slug,
                observed_at = excluded.observed_at, shelf_position = excluded.shelf_position,
                organic_position = excluded.organic_position, is_ad = excluded.is_ad, ad_type = excluded.ad_type,
                brand_raw = excluded.brand_raw, brand_key = excluded.brand_key, is_client_brand = excluded.is_client_brand,
                platform_product_id = excluded.platform_product_id, product_name = excluded.product_name,
                pack_raw = excluded.pack_raw, stock_status = excluded.stock_status, inventory_units = excluded.inventory_units,
                inventory_is_capped = excluded.inventory_is_capped, selling_price = excluded.selling_price, mrp = excluded.mrp,
                shelf_cards_seen = excluded.shelf_cards_seen, shelf_total_items = excluded.shelf_total_items,
                shelf_complete = excluded.shelf_complete, dq_status = excluded.dq_status, dq_flags = excluded.dq_flags,
                loaded_at = now(), etl_run_id = excluded.etl_run_id
            where (t.snapshot_id, t.store_key, t.city_slug, t.observed_at, t.shelf_position, t.organic_position, t.is_ad, t.ad_type,
                   t.brand_raw, t.brand_key, t.is_client_brand, t.platform_product_id, t.product_name, t.pack_raw, t.stock_status,
                   t.inventory_units, t.inventory_is_capped, t.selling_price, t.mrp, t.shelf_cards_seen, t.shelf_total_items,
                   t.shelf_complete, t.dq_status, t.dq_flags)
                  is distinct from
                  (excluded.snapshot_id, excluded.store_key, excluded.city_slug, excluded.observed_at, excluded.shelf_position,
                   excluded.organic_position, excluded.is_ad, excluded.ad_type, excluded.brand_raw, excluded.brand_key,
                   excluded.is_client_brand, excluded.platform_product_id, excluded.product_name, excluded.pack_raw,
                   excluded.stock_status, excluded.inventory_units, excluded.inventory_is_capped, excluded.selling_price,
                   excluded.mrp, excluded.shelf_cards_seen, excluded.shelf_total_items, excluded.shelf_complete,
                   excluded.dq_status, excluded.dq_flags)
            returning (xmax = 0) as inserted)
        select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;

        v_p := silver.refresh_category_products(p_run, p_lo, p_hi);

        return jsonb_build_object('stores', v_new_stores, 'ins', v_ins, 'upd', v_upd,
                                  'pb', (v_p ->> 'brands')::int, 'pi', (v_p ->> 'ins')::int,
                                  'pu', (v_p ->> 'upd')::int, 'pl', (v_p ->> 'linked')::int, 'dead_lettered', 0);
end $function$
;

CREATE OR REPLACE FUNCTION silver.refresh_category_market(p_full boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare
    sc record; v_key text; v_s jsonb; v_scopes jsonb := '{}'::jsonb; v_failed jsonb := '[]'::jsonb;
    v_ins bigint := 0; v_upd bigint := 0;
begin
    -- silver_069: center_lat / center_lon stay in bronze (map display only; dash and the portal never read them)
    insert into silver.dim_city (city_slug, city_name, state)
    select c.slug, c.name, c.state from public.cities c
    on conflict (city_slug) do update set
        city_name = excluded.city_name, state = excluded.state
    where (silver.dim_city.city_name, silver.dim_city.state)
          is distinct from (excluded.city_name, excluded.state);

    for sc in select platform, l1_id, l2_id from silver.category_scope where is_enabled order by 1, 2, 3 loop
        v_key := sc.platform || '/' || sc.l1_id || '/' || sc.l2_id;
        begin
            v_s := silver.refresh_category_scope(sc.platform, sc.l1_id, sc.l2_id, p_full);
            v_scopes := v_scopes || jsonb_build_object(v_key, v_s || jsonb_build_object('ok', true));
            v_ins := v_ins + coalesce((v_s -> 'fact_shelf_position' ->> 'inserted')::bigint, 0);
            v_upd := v_upd + coalesce((v_s -> 'fact_shelf_position' ->> 'updated')::bigint, 0);
        exception when others then
            v_failed := v_failed || to_jsonb(v_key);
            v_scopes := v_scopes || jsonb_build_object(v_key, jsonb_build_object('ok', false, 'error', sqlerrm, 'sqlstate', sqlstate));
            update silver.category_scope set last_status = 'failed', last_error = left(sqlerrm, 500),
                   consecutive_failures = consecutive_failures + 1
             where platform = sc.platform and l1_id = sc.l1_id and l2_id = sc.l2_id;
        end;
    end loop;
    return jsonb_build_object('mode', case when p_full then 'full' else 'incremental' end,
                              'scopes', v_scopes, 'failed_scopes', v_failed,
                              'fact_shelf_position', jsonb_build_object('inserted', v_ins, 'updated', v_upd));
end $function$
;

CREATE OR REPLACE FUNCTION silver.refresh_brand(p_brand_key text DEFAULT 'mr munchies'::text, p_full boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare
    v_scope  silver.brand_scope%rowtype;
    v_run    bigint;
    v_stats  jsonb := '{}'::jsonb;
    v_ins    int;
    v_upd    int;
    v_full   boolean;
    v_lb     bigint := coalesce(silver.cfg('incremental_lookback_rows'), 5000)::bigint;
    w_obs bigint := 0; w_sc bigint := 0; w_sp bigint := 0; w_ssn bigint := 0;
    v_excl   boolean := coalesce(silver.cfg('exclude_incomplete_reads'), 1) = 1;
begin
    select * into v_scope from silver.brand_scope where brand_key = p_brand_key;
    if not found then
        raise exception 'unknown brand_key "%": add it to silver.brand_scope first', p_brand_key;
    end if;
    if not v_scope.is_enabled then
        raise exception 'brand "%" is disabled in silver.brand_scope', p_brand_key;
    end if;

    v_full := p_full or not exists (select 1 from ops.etl_run where brand_key = p_brand_key and status = 'success');
    if not v_full then
        select coalesce(greatest(max(last_seen_id) filter (where source_table = 'observations')     - v_lb, 0), 0),
               coalesce(greatest(max(last_seen_id) filter (where source_table = 'search_cards')      - v_lb, 0), 0),
               coalesce(greatest(max(last_seen_id) filter (where source_table = 'shelf_positions')   - v_lb, 0), 0),
               coalesce(greatest(max(last_seen_id) filter (where source_table = 'search_snapshots')  - v_lb, 0), 0)
          into w_obs, w_sc, w_sp, w_ssn
          from silver.pipeline_source where source_schema = 'public';
    end if;

    insert into ops.etl_run (brand_key) values (p_brand_key) returning run_id into v_run;

    drop table if exists _brand_strings, _listings, _raw, _store_ids, _scans,
                         _cat_src, _cat_best, _prod_src, _prod;

    perform silver.refresh_brand_strings(v_full);

    -- silver_069: center_lat / center_lon stay in bronze (map display only; dash and the portal never read them)
    insert into silver.dim_city (city_slug, city_name, state)
    select c.slug, c.name, c.state from public.cities c
    on conflict (city_slug) do update set
        city_name = excluded.city_name, state = excluded.state
    where (silver.dim_city.city_name, silver.dim_city.state)
          is distinct from (excluded.city_name, excluded.state);

    insert into silver.dim_brand (brand_key, brand_name, company_name, is_tracked)
    values (v_scope.brand_key, v_scope.brand_name, v_scope.company_name, true)
    on conflict (brand_key) do update set
        brand_name = excluded.brand_name, company_name = excluded.company_name
    where (silver.dim_brand.brand_name, silver.dim_brand.company_name)
          is distinct from (excluded.brand_name, excluded.company_name);

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
           null::text                     as image_url,
           null::text                     as read_status,      -- silver_069: a product check has no snapshot
           null::boolean                  as read_complete,
           silver.safe_int(o.details::jsonb ->> 'max_allowed_quantity') as max_allowed_quantity,
           nullif(btrim(o.details::jsonb ->> 'pack_size'), '')         as pack_size_seen,
           nullif(btrim(o.details::jsonb ->> 'store_role'), '')        as store_role,
           null::text                     as matched_by,
           null::text                     as variant_of
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
           pp.ptype, pp.name, pp.brand, pp.pack, pp.image_url,
           ss.status::text, ss.complete::boolean, null::int, null::text, null::text,
           c.matched_by::text, c.variant_of::text
    from public.search_cards c
    join public.search_snapshots ss on ss.id = c.snapshot_id
    join public.platform_products pp on pp.platform = ss.platform and pp.external_id = c.external_id
    where c.id > w_sc
      and pp.brand in (select b from _brand_strings)
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
           pp.ptype, pp.name, pp.brand, pp.pack, pp.image_url,
           sn.status::text, sn.complete::boolean, null::int, null::text, null::text, null::text, null::text
    from public.shelf_positions sp
    join public.shelf_snapshots sn on sn.id = sp.snapshot_id
    join public.platform_products pp on pp.platform = sn.platform and pp.external_id = sp.external_id
    where sp.id > w_sp
      and pp.brand in (select b from _brand_strings)
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
            store_name = excluded.store_name, city_slug = coalesce(excluded.city_slug, silver.dim_store.city_slug),
            latitude = excluded.latitude, longitude = excluded.longitude,
            first_seen_at = excluded.first_seen_at, last_seen_at = excluded.last_seen_at
        where (silver.dim_store.store_name, silver.dim_store.city_slug, silver.dim_store.latitude, silver.dim_store.longitude, silver.dim_store.first_seen_at, silver.dim_store.last_seen_at)
              is distinct from (excluded.store_name, coalesce(excluded.city_slug, silver.dim_store.city_slug), excluded.latitude, excluded.longitude, excluded.first_seen_at, excluded.last_seen_at)
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
        where (silver.dim_product.brand_key, silver.dim_product.product_name, silver.dim_product.variant, silver.dim_product.product_type,
               silver.dim_product.pack_raw, silver.dim_product.size_value, silver.dim_product.size_unit, silver.dim_product.pack_count,
               silver.dim_product.category_key, silver.dim_product.listing_id, silver.dim_product.catalog_product_id,
               silver.dim_product.image_url, silver.dim_product.product_url)
              is distinct from
              (excluded.brand_key, excluded.product_name, excluded.variant, coalesce(excluded.product_type, silver.dim_product.product_type),
               excluded.pack_raw, excluded.size_value, excluded.size_unit, excluded.pack_count,
               coalesce(excluded.category_key, silver.dim_product.category_key), coalesce(excluded.listing_id, silver.dim_product.listing_id),
               coalesce(excluded.catalog_product_id, silver.dim_product.catalog_product_id),
               coalesce(excluded.image_url, silver.dim_product.image_url), coalesce(excluded.product_url, silver.dim_product.product_url))
        returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;
    v_stats := v_stats || jsonb_build_object('dim_product', jsonb_build_object('inserted', v_ins, 'updated', v_upd));

    with ins as (
        insert into silver.fact_product_reading (
            source_type, source_table, source_record_id, product_key, store_key, planned_store_key,
            city_slug, job_ref, run_id, scrape_id, snapshot_id, listing_id, observed_at,
            stock_state_raw, stock_status, is_listed, is_available, inventory_units, inventory_is_capped,
            selling_price, mrp, search_position, organic_position, is_ad, ad_type,
            osa_eligible, dq_status, dq_flags, etl_run_id,
            read_status, read_complete, max_allowed_quantity, pack_size_seen, store_role, matched_by, variant_of)
        select r.source_type, r.source_table, r.source_record_id, dp.product_key, ds.store_key, dps.store_key,
               ds.city_slug, r.job_ref, r.run_id, r.scrape_id, r.snapshot_id, r.listing_id, r.observed_at,
               r.state, q.status, q.status <> 'not_listed',
               case q.status when 'in_stock' then true when 'out_of_stock' then false end,
               r.inventory, coalesce(r.inventory_capped, false),
               round(r.price, 2), round(r.mrp, 2), r.pos, r.opos, r.is_ad, r.ad_type,
               (r.source_type = 'stock_check' and q.status in ('in_stock', 'out_of_stock')
                                              and silver.dq_status(q.flags) = 'valid'),
               silver.dq_status(q.flags), q.flags, v_run,
               r.read_status, r.read_complete, r.max_allowed_quantity, r.pack_size_seen, r.store_role,
               r.matched_by, r.variant_of
        from _raw r
        join silver.dim_product dp on dp.platform = r.platform and dp.platform_product_id = r.platform_product_id
        left join silver.dim_store ds  on ds.source_store_id  = r.src_store_id
        left join silver.dim_store dps on dps.source_store_id = r.planned_store_id
        cross join lateral (
            select silver.read_stock_status(silver.map_stock_status(r.state), r.read_status, r.read_complete, v_excl) as st) st0
        cross join lateral (
            -- silver_069: a failed or incomplete read never produces out_of_stock; the row is kept and flagged
            select st0.st as status,
                   silver.reading_dq(true, ds.store_key is not null, r.observed_at,
                                     st0.st, r.inventory,
                                     round(r.price, 2), round(r.mrp, 2))
                   || silver.read_flags(r.read_status, r.read_complete, v_excl) as flags) q
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
            read_status = excluded.read_status, read_complete = excluded.read_complete,
            max_allowed_quantity = excluded.max_allowed_quantity, pack_size_seen = excluded.pack_size_seen,
            store_role = excluded.store_role, matched_by = excluded.matched_by, variant_of = excluded.variant_of,
            loaded_at = now(), etl_run_id = excluded.etl_run_id
        where (silver.fact_product_reading.product_key, silver.fact_product_reading.store_key, silver.fact_product_reading.planned_store_key,
               silver.fact_product_reading.city_slug, silver.fact_product_reading.job_ref, silver.fact_product_reading.run_id,
               silver.fact_product_reading.scrape_id, silver.fact_product_reading.snapshot_id, silver.fact_product_reading.listing_id,
               silver.fact_product_reading.observed_at, silver.fact_product_reading.stock_state_raw, silver.fact_product_reading.stock_status,
               silver.fact_product_reading.is_listed, silver.fact_product_reading.is_available, silver.fact_product_reading.inventory_units,
               silver.fact_product_reading.inventory_is_capped, silver.fact_product_reading.selling_price, silver.fact_product_reading.mrp,
               silver.fact_product_reading.search_position, silver.fact_product_reading.organic_position, silver.fact_product_reading.is_ad,
               silver.fact_product_reading.ad_type, silver.fact_product_reading.osa_eligible, silver.fact_product_reading.dq_status,
               silver.fact_product_reading.dq_flags, silver.fact_product_reading.read_status, silver.fact_product_reading.read_complete,
               silver.fact_product_reading.max_allowed_quantity, silver.fact_product_reading.pack_size_seen,
               silver.fact_product_reading.store_role, silver.fact_product_reading.matched_by, silver.fact_product_reading.variant_of)
              is distinct from
              (excluded.product_key, excluded.store_key, excluded.planned_store_key, excluded.city_slug, excluded.job_ref, excluded.run_id,
               excluded.scrape_id, excluded.snapshot_id, excluded.listing_id, excluded.observed_at, excluded.stock_state_raw, excluded.stock_status,
               excluded.is_listed, excluded.is_available, excluded.inventory_units, excluded.inventory_is_capped, excluded.selling_price, excluded.mrp,
               excluded.search_position, excluded.organic_position, excluded.is_ad, excluded.ad_type, excluded.osa_eligible, excluded.dq_status,
               excluded.dq_flags, excluded.read_status, excluded.read_complete, excluded.max_allowed_quantity, excluded.pack_size_seen,
               excluded.store_role, excluded.matched_by, excluded.variant_of)
        returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;
    v_stats := v_stats || jsonb_build_object('fact_product_reading', jsonb_build_object('inserted', v_ins, 'updated', v_upd));

    with ins as (
        insert into silver.fact_store_scan (
            snapshot_id, scrape_id, scrape_query, platform, brand_key, store_key, planned_store_key,
            city_slug, scanned_at, scan_status, cards_seen, brand_cards_matched,
            is_complete, stopped_early, is_valid_denominator, dq_flags, etl_run_id,
            search_query, latitude, longitude, scan_error)
        select s.id, s.scrape_id, bs.query, s.platform, p_brand_key, ds.store_key, dps.store_key,
               coalesce(ds.city_slug, dps.city_slug, sc_city.city_slug), s.taken_at, s.status, s.cards_seen,
               s.cards_matched, s.complete, s.stopped_early,
               (s.status = 'ok' and ds.store_key is not null),
               array_remove(array[
                   case when ds.store_key is null then 'no_store' end,
                   case when s.status <> 'ok' then 'scan_' || s.status end,
                   case when s.store_id is not null and s.store_id is distinct from s.planned_store_id
                        then 'info_store_differs_from_planned' end,
                   case when s.complete is false then 'info_scan_incomplete' end,
                   case when ds.city_slug is null and dps.city_slug is null and sc_city.city_slug is not null
                        then 'info_city_from_snapshot' end], null),
               v_run,
               nullif(btrim(s.query::text), ''), s.lat::double precision, s.lon::double precision,
               nullif(left(s.error::text, 1000), '')
        from _scans s
        left join public.brand_scrapes bs on bs.id = s.scrape_id
        left join silver.dim_store ds  on ds.source_store_id  = s.store_id
        left join silver.dim_store dps on dps.source_store_id = s.planned_store_id
        left join silver.dim_city sc_city on sc_city.city_slug = s.city_slug    -- silver_069: only known cities (FK)
        on conflict (snapshot_id) do update set
            scrape_query = excluded.scrape_query, store_key = excluded.store_key,
            planned_store_key = excluded.planned_store_key, city_slug = excluded.city_slug,
            scanned_at = excluded.scanned_at, scan_status = excluded.scan_status,
            cards_seen = excluded.cards_seen,
            brand_cards_matched = excluded.brand_cards_matched, is_complete = excluded.is_complete,
            stopped_early = excluded.stopped_early, is_valid_denominator = excluded.is_valid_denominator,
            dq_flags = excluded.dq_flags, search_query = excluded.search_query, latitude = excluded.latitude,
            longitude = excluded.longitude, scan_error = excluded.scan_error,
            loaded_at = now(), etl_run_id = excluded.etl_run_id
        where (silver.fact_store_scan.scrape_query, silver.fact_store_scan.store_key, silver.fact_store_scan.planned_store_key,
               silver.fact_store_scan.city_slug, silver.fact_store_scan.scanned_at, silver.fact_store_scan.scan_status,
               silver.fact_store_scan.cards_seen, silver.fact_store_scan.brand_cards_matched, silver.fact_store_scan.is_complete,
               silver.fact_store_scan.stopped_early, silver.fact_store_scan.dq_flags, silver.fact_store_scan.search_query,
               silver.fact_store_scan.latitude, silver.fact_store_scan.longitude, silver.fact_store_scan.scan_error)
              is distinct from
              (excluded.scrape_query, excluded.store_key, excluded.planned_store_key, excluded.city_slug, excluded.scanned_at, excluded.scan_status,
               excluded.cards_seen, excluded.brand_cards_matched, excluded.is_complete, excluded.stopped_early, excluded.dq_flags,
               excluded.search_query, excluded.latitude, excluded.longitude, excluded.scan_error)
        returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;
    v_stats := v_stats || jsonb_build_object('fact_store_scan', jsonb_build_object('inserted', v_ins, 'updated', v_upd));

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

    update ops.etl_run set finished_at = now(), status = 'success', stats = v_stats where run_id = v_run;
    return v_stats;
end
$function$
;


-- 4. one-off backfill for rows loaded before silver_069 (idempotent; returns what it changed)
CREATE OR REPLACE FUNCTION silver.backfill_read_flags(p_shelf_limit integer DEFAULT 200000)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare
    v_excl boolean := coalesce(silver.cfg('exclude_incomplete_reads'), 1) = 1;
    n_read bigint; n_shelf bigint;
begin
    with src as (
        select f.reading_key, f.source_type, f.store_key, f.observed_at, f.inventory_units, f.selling_price, f.mrp,
               f.stock_state_raw,
               case f.source_type when 'brand_search' then ss.status::text when 'category_shelf' then sn.status::text end as rs,
               case f.source_type when 'brand_search' then ss.complete::boolean when 'category_shelf' then sn.complete::boolean end as rc,
               silver.safe_int(o.details::jsonb ->> 'max_allowed_quantity') as maq,
               nullif(btrim(o.details::jsonb ->> 'pack_size'), '')         as psz,
               nullif(btrim(o.details::jsonb ->> 'store_role'), '')        as srole,
               c.matched_by::text as mb, c.variant_of::text as vo
          from silver.fact_product_reading f
          left join public.observations o      on f.source_type = 'stock_check'    and o.id = f.source_record_id
          left join public.search_cards c      on f.source_type = 'brand_search'   and c.id = f.source_record_id
          left join public.search_snapshots ss on ss.id = c.snapshot_id
          left join public.shelf_positions sp  on f.source_type = 'category_shelf' and sp.id = f.source_record_id
          left join public.shelf_snapshots sn  on sn.id = sp.snapshot_id
    ), calc as (
        select s.*, st.st,
               silver.reading_dq(true, s.store_key is not null, s.observed_at, st.st, s.inventory_units, s.selling_price, s.mrp)
               || silver.read_flags(s.rs, s.rc, v_excl) as flags
          from src s
         cross join lateral (select silver.read_stock_status(silver.map_stock_status(s.stock_state_raw), s.rs, s.rc, v_excl) as st) st
    )
    update silver.fact_product_reading f
       set read_status = c.rs, read_complete = c.rc, max_allowed_quantity = c.maq, pack_size_seen = c.psz,
           store_role = c.srole, matched_by = c.mb, variant_of = c.vo,
           stock_status = c.st, is_listed = c.st <> 'not_listed',
           is_available = case c.st when 'in_stock' then true when 'out_of_stock' then false end,
           dq_flags = c.flags, dq_status = silver.dq_status(c.flags),
           osa_eligible = (c.source_type = 'stock_check' and c.st in ('in_stock', 'out_of_stock')
                           and silver.dq_status(c.flags) = 'valid')
      from calc c
     where f.reading_key = c.reading_key
       and (f.read_status, f.read_complete, f.max_allowed_quantity, f.pack_size_seen, f.store_role, f.matched_by,
            f.variant_of, f.stock_status, f.dq_flags)
           is distinct from (c.rs, c.rc, c.maq, c.psz, c.srole, c.mb, c.vo, c.st, c.flags);
    get diagnostics n_read = row_count;

    -- category shelves: only rows of incomplete reads change; shelf_complete is already stored on the row
    with todo as (
        select f.shelf_pos_key, st.st,
               silver.reading_dq(true, f.store_key is not null, f.observed_at, st.st, f.inventory_units, f.selling_price, f.mrp)
               || silver.read_flags('ok', false, v_excl) as flags
          from silver.fact_shelf_position f
         cross join lateral (select silver.read_stock_status(f.stock_status, 'ok', false, v_excl) as st) st
         where f.shelf_complete is false
           and not (f.dq_flags && array['read_incomplete', 'info_read_incomplete'])
         limit p_shelf_limit)
    update silver.fact_shelf_position f
       set stock_status = t.st, dq_flags = t.flags, dq_status = silver.dq_status(t.flags)
      from todo t
     where f.shelf_pos_key = t.shelf_pos_key;
    get diagnostics n_shelf = row_count;

    return jsonb_build_object('fact_product_reading_updated', n_read, 'fact_shelf_position_updated', n_shelf,
                              'shelf_done', n_shelf < p_shelf_limit, 'exclude_incomplete_reads', v_excl);
end $function$
;

comment on function silver.backfill_read_flags(integer) is 'silver_069 one-off: applies the new bronze columns and read_failed/read_incomplete flags to rows loaded earlier. Idempotent; repeat until shelf_done = true.';
comment on function silver.read_flags(text, boolean, boolean) is 'read_failed (snapshot status <> ok, invalid) / read_incomplete (complete = false, suspect) / info_read_incomplete (knob off).';
comment on function silver.read_stock_status(text, text, boolean, boolean) is 'A failed or incomplete read never yields out_of_stock: it becomes unknown (silver_069).';
comment on function silver.safe_int(text) is 'text -> integer, NULL for anything that is not a plain integer (bronze JSON fields).';
comment on column silver.fact_product_reading.read_status is 'bronze snapshot status (search / shelf); NULL for product checks';
comment on column silver.fact_product_reading.read_complete is 'bronze snapshot complete flag; false = partial read, never counted as out of stock';
comment on column silver.fact_product_reading.max_allowed_quantity is 'observations.details.max_allowed_quantity (units cap per order)';
comment on column silver.fact_product_reading.pack_size_seen is 'observations.details.pack_size as shown at that store';
comment on column silver.fact_product_reading.store_role is 'observations.details.store_role';
comment on column silver.fact_product_reading.matched_by is 'search_cards.matched_by: how the card was matched to the brand';
comment on column silver.fact_product_reading.variant_of is 'search_cards.variant_of';
comment on column silver.fact_store_scan.search_query is 'search_snapshots.query (the query actually sent; scrape_query is the scrape job''s query)';
comment on column silver.fact_store_scan.scan_error is 'search_snapshots.error';
