-- Rollbacks for the pending migrations, newest first. Append each block to sql/rollbacks.sql when its migration
-- is applied. Function bodies below are the exact live text before the change (from sql/02_functions.sql, silver_068).

-- ===================================================================================== rollback dash_011
select cron.unschedule('sidnl-context');
drop function if exists dash.refresh_context();
drop table if exists dash.collection_health;
drop table if exists dash.coverage;
delete from dash.refresh_state where key = 'context_refreshed_at';

-- ===================================================================================== rollback silver_072
CREATE OR REPLACE FUNCTION silver.dq_checks(p_shelf_max bigint DEFAULT NULL::bigint)
 RETURNS TABLE(check_name text, severity text, scope text, violations bigint, total bigint, ok boolean, blocks boolean, detail text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
with pct as (select coalesce(silver.cfg('dq_reject_block_pct'), 5) as p),
lb  as (select coalesce(greatest(ps.last_seen_id - coalesce(silver.cfg('incremental_lookback_rows'), 5000)::bigint, 0), 0) as lo
          from silver.pipeline_source ps where ps.source_schema = 'public' and ps.source_table = 'shelf_positions'),
t as (
    select f.platform, f.l1_id, f.l2_id, count(*) as total,
           count(*) filter (where 'negative_price' = any (f.dq_flags))                       as neg,
           count(*) filter (where 'sp_gt_mrp'      = any (f.dq_flags))                       as sp,
           count(*) filter (where f.product_key is null and f.platform_product_id is not null) as unlinked,
           count(*) filter (where f.store_key is null)                                       as nostore,
           count(*) filter (where b.brand_key is null)                                       as nobrand
      from silver.fact_shelf_position f
      left join silver.dim_brand b on b.brand_key = f.brand_key
     group by 1, 2, 3),
m as (
    select sn.platform, sn.l1_id, sn.l2_id, count(*) as missing
      from public.shelf_positions sp
      join public.shelf_snapshots sn on sn.id = sp.snapshot_id
      join silver.category_scope cs on cs.platform = sn.platform and cs.l1_id = sn.l1_id
                                   and cs.l2_id = sn.l2_id and cs.is_enabled
      join silver.dim_platform dpl on dpl.platform = sn.platform and not dpl.is_test
      cross join lb
     where sn.status = 'ok' and sp.id > lb.lo
       and sp.id <= coalesce(p_shelf_max, (select max(id) from public.shelf_positions))
       and not exists (select 1 from silver.fact_shelf_position f where f.source_record_id = sp.id)
     group by 1, 2, 3),
per_scope as (
    select c.n, c.sev, t.platform || '/' || t.l1_id || '/' || t.l2_id as scope, c.v, t.total, coalesce(c.blk, false) as blk, c.d
      from t cross join pct
      cross join lateral (values
        ('shelf_negative_selling_price', 'rejected', t.neg,
            t.neg * 100.0 / nullif(t.total, 0) > pct.p,
            'rows rejected from valid analytical output (dq_status=invalid); scope blocked only above dq_reject_block_pct'),
        ('shelf_selling_price_above_mrp', 'warning', t.sp, false,
            'rows flagged suspect and excluded from price/discount metrics; never blocks'),
        ('shelf_row_without_product', 'blocking', t.unlinked, t.unlinked > 0,
            'referential integrity: shelf row has a platform_product_id but no dim_product link'),
        ('shelf_row_without_store', 'blocking', t.nostore, t.nostore > 0,
            'referential integrity: shelf row has no dim_store'),
        ('shelf_row_brand_not_in_dim_brand', 'blocking', t.nobrand, t.nobrand > 0,
            'referential integrity: brand_key missing in dim_brand')
      ) c (n, sev, v, blk, d)
    union all
    select 'shelf_bronze_rows_not_in_silver', 'blocking', m.platform || '/' || m.l1_id || '/' || m.l2_id,
           m.missing, t.total, m.missing > 0,
           'unprocessed bronze rows inside the processing window - watermark must not advance'
      from m left join t on t.platform = m.platform and t.l1_id = m.l1_id and t.l2_id = m.l2_id)
select n, sev, scope, v, total, false, blk, d from per_scope where v > 0
union all
select n, sev, 'all', coalesce(sum(v), 0), coalesce(sum(total), 0), coalesce(sum(v), 0) = 0, coalesce(bool_or(blk), false), min(d)
  from per_scope group by n, sev
union all
select 'dim_store_without_city_or_coords', 'accepted', 'dim_store',
       count(*) filter (where city_slug is null or latitude is null or longitude is null), count(*), true, false,
       'optional descriptive NULLs: kept NULL, not derivable from source'
  from silver.dim_store
union all
select 'dim_product_without_category', 'accepted', 'dim_product',
       count(*) filter (where category_key is null), count(*), true, false,
       'optional descriptive NULLs: kept NULL, not derivable from source'
  from silver.dim_product
union all
select 'canonical_empty_name_clean', 'accepted', 'canonical_product',
       count(*) filter (where coalesce(name_clean, '') = ''), count(*), true, false,
       'approved: unchanged, SI id and raw name preserved'
  from silver.canonical_product where is_active
union all
select 'canonical:' || q.check_name, 'blocking', 'canonical',
       case when q.ok then 0 else 1 end, 1, q.ok, not q.ok, q.detail
  from silver.quality_checks() q
$function$
;

drop index if exists silver.ix_fsp_unlinked;
drop index if exists silver.ix_fsp_no_store;
delete from silver.sidnl_config where key = 'dq_gate_window';

-- ===================================================================================== rollback silver_071
CREATE OR REPLACE FUNCTION silver.selftest_parser()
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare
    p silver.pack_t;
begin
    assert silver.norm_key('Mr. Munchies')   = 'mr munchies',  'norm_key dotted';
    assert silver.norm_key('MR.MUNCHIES')    = 'mr munchies',  'norm_key upper';
    assert silver.norm_key('Mr.Munchies')    = 'mr munchies',  'norm_key no space';
    assert silver.norm_key('Lay''s')         = 'lays',         'norm_key apostrophe';
    assert silver.norm_key('Crunch & Munch') = 'crunch and munch', 'norm_key ampersand';
    assert silver.norm_key('   ')            is null,          'norm_key blank';
    assert silver.norm_key(null)             is null,          'norm_key null';

    assert silver.brand_matches('mr munchies', 'Mr. Munchies'),     'brand exact';
    assert silver.brand_matches('mr munchies', 'MrMunchies'),       'brand compact';
    assert silver.brand_matches('mr munchies', 'mr-munchies'),      'brand hyphen';
    assert not silver.brand_matches('mr munchies', 'Crunch & Munch'), 'brand must not substring-match';
    assert not silver.brand_matches('mr munchies', 'Nestle Munch'),   'brand must not substring-match 2';
    assert not silver.brand_matches('mr munchies', null),             'brand null';

    p := silver.parse_pack('270 g');
    assert (p.size_value, p.size_unit, p.pack_count) = (270, 'g', 1), 'pack 270 g';
    p := silver.parse_pack('1 pc (38.5 g)');
    assert (p.size_value, p.size_unit, p.pack_count) = (38.5, 'g', 1), 'pack 1 pc (38.5 g)';
    p := silver.parse_pack('330 ml');
    assert (p.size_value, p.size_unit, p.pack_count) = (330, 'ml', 1), 'pack 330 ml';
    p := silver.parse_pack('1 L');
    assert (p.size_value, p.size_unit, p.pack_count) = (1000, 'ml', 1), 'pack 1 L -> 1000 ml';
    p := silver.parse_pack('1.5 Ltr');
    assert (p.size_value, p.size_unit, p.pack_count) = (1500, 'ml', 1), 'pack 1.5 Ltr';
    p := silver.parse_pack('2 kg');
    assert (p.size_value, p.size_unit, p.pack_count) = (2000, 'g', 1), 'pack 2 kg';
    p := silver.parse_pack('6 x 330 ml');
    assert (p.size_value, p.size_unit, p.pack_count) = (330, 'ml', 6), 'pack 6 x 330 ml';
    p := silver.parse_pack('0,5 kg');
    assert (p.size_value, p.size_unit, p.pack_count) = (500, 'g', 1), 'pack decimal comma';
    p := silver.parse_pack('1 N');
    assert (p.size_value, p.size_unit, p.pack_count) = (1, 'pc', 1), 'pack 1 N';
    p := silver.parse_pack('3 pcs');
    assert (p.size_value, p.size_unit, p.pack_count) = (3, 'pc', 1), 'pack 3 pcs = one pack of 3 pieces';
    p := silver.parse_pack(null);
    assert p.size_value is null and p.pack_count = 1, 'pack null';
    p := silver.parse_pack('assorted');
    assert p.size_value is null or p.size_unit = 'pc', 'pack junk does not crash';

    -- silver_056: exact pack strings seen in bronze public.platform_products
    p := silver.parse_pack('100 g X 2');
    assert (p.size_value, p.size_unit, p.pack_count) = (100, 'g', 2), 'pack 100 g X 2';
    p := silver.parse_pack('500 ml X 4');
    assert (p.size_value, p.size_unit, p.pack_count) = (500, 'ml', 4), 'pack 500 ml X 4';
    p := silver.parse_pack('2 x 1 pc');
    assert (p.size_value, p.size_unit, p.pack_count) = (1, 'pc', 2), 'pack 2 x 1 pc';
    p := silver.parse_pack('2 x 10 pcs');
    assert (p.size_value, p.size_unit, p.pack_count) = (10, 'pc', 2), 'pack 2 x 10 pcs';
    p := silver.parse_pack('10 pcs');
    assert (p.size_value, p.size_unit, p.pack_count) = (10, 'pc', 1), 'pack 10 pcs';
    p := silver.parse_pack('30 tabs');
    assert (p.size_value, p.size_unit, p.pack_count) = (30, 'pc', 1), 'pack 30 tabs';
    p := silver.parse_pack('60 capsules');
    assert (p.size_value, p.size_unit, p.pack_count) = (60, 'pc', 1), 'pack 60 capsules';
    p := silver.parse_pack('4 packs');
    assert (p.size_value, p.size_unit, p.pack_count) = (4, 'pc', 1), 'pack 4 packs';
    p := silver.parse_pack('1 unit + 1 unit');
    assert (p.size_value, p.size_unit, p.pack_count) = (1, 'pc', 2), 'pack 1 unit + 1 unit';
    p := silver.parse_pack('40U x 25g');
    assert (p.size_value, p.size_unit, p.pack_count) = (25, 'g', 40), 'pack 40U x 25g';
    p := silver.parse_pack('7 pcs + 102 g');
    assert (p.size_value, p.size_unit, p.pack_count) = (102, 'g', 1), 'pack 7 pcs + 102 g does not multiply';
    p := silver.parse_pack('1 pack (1.25 kg)');
    assert (p.size_value, p.size_unit, p.pack_count) = (1250, 'g', 1), 'pack 1 pack (1.25 kg)';
    p := silver.parse_pack('1 pack (5 X 10 ml)');
    assert (p.size_value, p.size_unit, p.pack_count) = (10, 'ml', 5), 'pack 1 pack (5 X 10 ml)';
    p := silver.parse_pack('2 x 45 g + 35 g');
    assert (p.size_value, p.size_unit, p.pack_count) = (125, 'g', 1), 'pack 2 x 45 g + 35 g';
    p := silver.parse_pack('100 g + 100 g');
    assert (p.size_value, p.size_unit, p.pack_count) = (100, 'g', 2), 'pack 100 g + 100 g';

    assert silver.parse_variant('Mr. Munchies Cheese Chilli Samosa (Frozen)', 'Mr. Munchies', 'Samosa') = 'Cheese Chilli', 'variant samosa';
    assert silver.parse_variant('Mr. Munchies Veg Spring Roll (Frozen)',      'Mr. Munchies', 'Spring Roll') = 'Veg', 'variant roll';
    assert silver.parse_variant('Mr. Munchies Spicy Frozen Paneer Bites',     'Mr. Munchies', 'Frozen Paneer Bites') = 'Spicy', 'variant paneer';
    assert silver.parse_variant('Mr. Munchies Lasooni Soya Chaap',            'Mr. Munchies', 'Soya Chaap') = 'Lasooni', 'variant chaap';
    assert silver.parse_variant('Mr. Munchies Samosa',                        'Mr. Munchies', 'Samosa') is null, 'variant empty -> null';

    assert silver.map_stock_status('in_stock')     = 'in_stock',     'state in';
    assert silver.map_stock_status('OUT_OF_STOCK') = 'out_of_stock', 'state out';
    assert silver.map_stock_status('not_listed')   = 'not_listed',   'state nl';
    assert silver.map_stock_status('weird')        = 'unknown',      'state unknown';
    assert silver.map_stock_status(null)           = 'unknown',      'state null';

    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',3,179,179)) = 'valid',   'dq clean';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'out_of_stock',0,null,null)) = 'valid', 'dq oos without price is valid';
    assert silver.dq_status(silver.reading_dq(true,false,now(),'in_stock',3,179,179)) = 'invalid', 'dq no store';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',-1,179,179)) = 'invalid', 'dq negative inv';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',3,200,179)) = 'suspect', 'dq sp > mrp';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',3,179,null)) = 'suspect', 'dq mrp missing';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'out_of_stock',4,179,179)) = 'suspect', 'dq oos with inventory';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',3,null,null)) = 'suspect', 'dq in stock no price';
    assert silver.dq_status(silver.reading_dq(true,true,now() + interval '30 days','in_stock',3,179,179)) = 'invalid', 'dq future ts';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'unknown',3,179,179)) = 'invalid', 'dq unknown state';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'not_listed',null,null,null)) = 'valid', 'dq not_listed valid';
    return 'all parser tests passed';
end
$function$
;

drop function if exists silver.selftest();
drop function if exists silver.selftest_pure();

-- ===================================================================================== rollback silver_070
-- (dq_status is restored by the silver_069 rollback below; until then the silver_070 version is a superset)
drop function if exists silver.refresh_scrape_context();
drop table if exists silver.fact_shelf_snapshot;
drop table if exists silver.fact_scrape_run;
drop table if exists silver.fact_serviceability;
drop table if exists silver.dim_sample_point;
drop table if exists silver.dim_listing;
drop table if exists silver.dim_catalog_product;
alter table silver.dim_product drop column if exists source_product_id;
delete from silver.sidnl_config where key = 'context_lookback_rows';

-- ===================================================================================== rollback silver_069
-- Re-adds the removed columns and refills them from bronze (store_weight was never written: it comes back empty).
alter table silver.dim_city add column if not exists center_lat double precision, add column if not exists center_lon double precision;
update silver.dim_city d set center_lat = c.center_lat, center_lon = c.center_lon from public.cities c where c.slug = d.city_slug;
alter table silver.dim_store add column if not exists "store_weight (weight per store, e.g. store sales)" numeric;
alter table silver.fact_store_scan add column if not exists pages_read integer;
update silver.fact_store_scan f set pages_read = s.pages_read from public.search_snapshots s where s.id = f.snapshot_id;
CREATE OR REPLACE FUNCTION silver.dq_status(p_flags text[])
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
    select case
        when p_flags && array['no_product','no_store','bad_timestamp','unknown_state',
                              'negative_inventory','negative_price'] then 'invalid'
        when p_flags && array['sp_gt_mrp','mrp_missing','oos_with_inventory',
                              'price_missing_in_stock'] then 'suspect'
        else 'valid' end
$function$
;

CREATE OR REPLACE FUNCTION silver.load_category_chunk(p_platform text, p_l1 text, p_l2 text, p_lo bigint, p_hi bigint, p_run bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare v_ins int; v_upd int; v_new_stores int; v_p jsonb;
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
                select silver.map_stock_status(s.state) as status,
                       silver.reading_dq(true, ds.store_key is not null, s.taken_at, silver.map_stock_status(s.state),
                                         s.inventory, round(s.price, 2), round(s.mrp, 2)) as flags) q
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
    insert into silver.dim_city (city_slug, city_name, state, center_lat, center_lon)
    select c.slug, c.name, c.state, c.center_lat, c.center_lon from public.cities c
    on conflict (city_slug) do update set
        city_name = excluded.city_name, state = excluded.state,
        center_lat = excluded.center_lat, center_lon = excluded.center_lon
    where (silver.dim_city.city_name, silver.dim_city.state, silver.dim_city.center_lat, silver.dim_city.center_lon)
          is distinct from (excluded.city_name, excluded.state, excluded.center_lat, excluded.center_lon);

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

    insert into silver.dim_city (city_slug, city_name, state, center_lat, center_lon)
    select c.slug, c.name, c.state, c.center_lat, c.center_lon from public.cities c
    on conflict (city_slug) do update set
        city_name = excluded.city_name, state = excluded.state,
        center_lat = excluded.center_lat, center_lon = excluded.center_lon
    where (silver.dim_city.city_name, silver.dim_city.state, silver.dim_city.center_lat, silver.dim_city.center_lon)
          is distinct from (excluded.city_name, excluded.state, excluded.center_lat, excluded.center_lon);

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
           pp.ptype, pp.name, pp.brand, pp.pack, pp.image_url
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
           pp.ptype, pp.name, pp.brand, pp.pack, pp.image_url
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
        where (silver.fact_product_reading.product_key, silver.fact_product_reading.store_key, silver.fact_product_reading.planned_store_key,
               silver.fact_product_reading.city_slug, silver.fact_product_reading.job_ref, silver.fact_product_reading.run_id,
               silver.fact_product_reading.scrape_id, silver.fact_product_reading.snapshot_id, silver.fact_product_reading.listing_id,
               silver.fact_product_reading.observed_at, silver.fact_product_reading.stock_state_raw, silver.fact_product_reading.stock_status,
               silver.fact_product_reading.is_listed, silver.fact_product_reading.is_available, silver.fact_product_reading.inventory_units,
               silver.fact_product_reading.inventory_is_capped, silver.fact_product_reading.selling_price, silver.fact_product_reading.mrp,
               silver.fact_product_reading.search_position, silver.fact_product_reading.organic_position, silver.fact_product_reading.is_ad,
               silver.fact_product_reading.ad_type, silver.fact_product_reading.osa_eligible, silver.fact_product_reading.dq_status,
               silver.fact_product_reading.dq_flags)
              is distinct from
              (excluded.product_key, excluded.store_key, excluded.planned_store_key, excluded.city_slug, excluded.job_ref, excluded.run_id,
               excluded.scrape_id, excluded.snapshot_id, excluded.listing_id, excluded.observed_at, excluded.stock_state_raw, excluded.stock_status,
               excluded.is_listed, excluded.is_available, excluded.inventory_units, excluded.inventory_is_capped, excluded.selling_price, excluded.mrp,
               excluded.search_position, excluded.organic_position, excluded.is_ad, excluded.ad_type, excluded.osa_eligible, excluded.dq_status,
               excluded.dq_flags)
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
        where (silver.fact_store_scan.scrape_query, silver.fact_store_scan.store_key, silver.fact_store_scan.planned_store_key,
               silver.fact_store_scan.city_slug, silver.fact_store_scan.scanned_at, silver.fact_store_scan.scan_status, silver.fact_store_scan.pages_read,
               silver.fact_store_scan.cards_seen, silver.fact_store_scan.brand_cards_matched, silver.fact_store_scan.is_complete,
               silver.fact_store_scan.stopped_early, silver.fact_store_scan.dq_flags)
              is distinct from
              (excluded.scrape_query, excluded.store_key, excluded.planned_store_key, excluded.city_slug, excluded.scanned_at, excluded.scan_status,
               excluded.pages_read, excluded.cards_seen, excluded.brand_cards_matched, excluded.is_complete, excluded.stopped_early, excluded.dq_flags)
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

drop function if exists silver.backfill_read_flags(integer);
-- rows flagged by silver_069 get their previous flags back on the next full reload:
--   select silver.run_pipeline(true, 'rollback-069');
alter table silver.fact_product_reading
    drop column if exists read_status, drop column if exists read_complete, drop column if exists max_allowed_quantity,
    drop column if exists pack_size_seen, drop column if exists store_role, drop column if exists matched_by,
    drop column if exists variant_of;
alter table silver.fact_store_scan
    drop column if exists search_query, drop column if exists latitude, drop column if exists longitude,
    drop column if exists scan_error;
drop function if exists silver.read_stock_status(text, text, boolean, boolean);
drop function if exists silver.read_flags(text, boolean, boolean);
drop function if exists silver.safe_int(text);
delete from silver.sidnl_config where key = 'exclude_incomplete_reads';
