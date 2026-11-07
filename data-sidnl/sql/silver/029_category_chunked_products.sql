-- Applied to Supabase as migration 20261107182732 (silver_029_category_chunked_products).
-- Exported from supabase_migrations.schema_migrations.

insert into silver.sidnl_config (key, value_num, description) values
    ('category_chunk_rows', 50000, 'refresh_category_market reads bronze shelf cards in id chunks of this size')
on conflict (key) do update set value_num = 50000;

drop function if exists silver.refresh_category_products(bigint);

create or replace function silver.refresh_category_products(p_run bigint, p_lo bigint, p_hi bigint)
returns jsonb
language plpgsql
set search_path to 'silver', 'public', 'pg_temp'
as $function$
declare v_b int; v_ins int; v_upd int; v_k int;
begin
    drop table if exists _cp_rows, _cp, _cp_brand;

    create temp table _cp_rows on commit drop as
    select f.source_record_id, f.platform, f.platform_product_id, f.l1_id, f.l2_id, f.brand_key, f.brand_raw,
           f.product_name, f.pack_raw, f.observed_at, sp.ptype, sp.image_url
    from silver.fact_shelf_position f
    join public.shelf_positions sp on sp.id = f.source_record_id
    where f.source_record_id > p_lo and f.source_record_id <= p_hi
      and f.etl_run_id = p_run and f.platform_product_id is not null;

    create temp table _cp_brand on commit drop as
    select distinct on (brand_key) brand_key, brand_raw
      from (select brand_key, brand_raw, count(*) n from _cp_rows where brand_key is not null group by 1, 2) z
     order by brand_key, n desc, brand_raw;

    insert into silver.brand_scope (brand_key, brand_name, company_name, raw_brand_aliases, is_enabled, scope_source)
    select b.brand_key, b.brand_raw, null, array[b.brand_raw], false, 'category_shelf'
    from _cp_brand b
    on conflict (brand_key) do nothing;

    with ins as (
        insert into silver.dim_brand (brand_key, brand_name, company_name, is_tracked)
        select b.brand_key, b.brand_raw, null, false from _cp_brand b
        on conflict (brand_key) do nothing
        returning 1)
    select count(*) into v_b from ins;

    insert into silver.dim_category (platform, l1_id, l1_name, l2_id, l2_name, l3_id, l3_name)
    select cs.platform, cs.l1_id, cs.l1_name, cs.l2_id, cs.l2_name, null, null
    from silver.category_scope cs
    where cs.is_enabled and exists (select 1 from _cp_rows r where r.platform = cs.platform and r.l1_id = cs.l1_id and r.l2_id = cs.l2_id)
    on conflict do nothing;

    create temp table _cp on commit drop as
    select distinct on (r.platform, r.platform_product_id)
           r.platform, r.platform_product_id as pid, r.brand_key, r.brand_raw, r.product_name as name, r.pack_raw as pack,
           r.ptype, r.image_url, r.l1_id, r.l2_id
    from _cp_rows r
    order by r.platform, r.platform_product_id, r.observed_at desc, r.source_record_id desc;

    with ins as (
        insert into silver.dim_product (platform, platform_product_id, brand_key, product_name, variant, product_type,
                                        pack_raw, size_value, size_unit, pack_count, category_key, image_url)
        select p.platform, p.pid, p.brand_key, coalesce(p.name, 'Unknown product ' || p.pid),
               silver.parse_variant(p.name, p.brand_raw, p.ptype), p.ptype, p.pack,
               pk.size_value, pk.size_unit, pk.pack_count, dc.category_key, p.image_url
        from _cp p
        cross join lateral silver.parse_pack(p.pack) pk
        left join lateral (select d.category_key from silver.dim_category d
                            where d.platform = p.platform and d.l1_id = p.l1_id and d.l2_id = p.l2_id
                            order by (d.l3_id is null) desc, d.category_key limit 1) dc on true
        on conflict (platform, platform_product_id) do update set
            product_name = excluded.product_name, variant = excluded.variant,
            product_type = coalesce(excluded.product_type, silver.dim_product.product_type),
            pack_raw = excluded.pack_raw, size_value = excluded.size_value, size_unit = excluded.size_unit,
            pack_count = excluded.pack_count,
            category_key = coalesce(silver.dim_product.category_key, excluded.category_key),
            image_url = coalesce(excluded.image_url, silver.dim_product.image_url)
        returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;

    update silver.fact_shelf_position f
       set product_key = dp.product_key
      from silver.dim_product dp
     where f.source_record_id > p_lo and f.source_record_id <= p_hi and f.etl_run_id = p_run
       and dp.platform = f.platform and dp.platform_product_id = f.platform_product_id
       and f.product_key is distinct from dp.product_key;
    get diagnostics v_k = row_count;

    update silver.dim_product p
       set first_seen_at = least(coalesce(p.first_seen_at, x.mn), x.mn),
           last_seen_at  = greatest(coalesce(p.last_seen_at, x.mx), x.mx)
      from (select platform, platform_product_id, min(observed_at) mn, max(observed_at) mx
              from _cp_rows group by 1, 2) x
     where p.platform = x.platform and p.platform_product_id = x.platform_product_id
       and (p.first_seen_at is null or p.last_seen_at is null or x.mn < p.first_seen_at or x.mx > p.last_seen_at);

    return jsonb_build_object('brands', v_b, 'ins', v_ins, 'upd', v_upd, 'linked', v_k);
end
$function$;

create or replace function silver.refresh_category_market(p_full boolean default false)
returns jsonb
language plpgsql
set search_path to 'silver', 'public', 'pg_temp'
as $function$
declare
    v_run bigint; v_ins int; v_upd int; v_new_stores int;
    v_tot_ins int := 0; v_tot_upd int := 0; v_tot_stores int := 0;
    v_pb int := 0; v_pi int := 0; v_pu int := 0; v_pl int := 0; v_p jsonb;
    v_stats jsonb := '{}'::jsonb;
    v_lb   bigint := coalesce(silver.cfg('incremental_lookback_rows'), 5000)::bigint;
    v_step bigint := coalesce(silver.cfg('category_chunk_rows'), 50000)::bigint;
    w_sp bigint := 0; v_start bigint; v_max bigint; v_lo bigint; v_hi bigint;
    v_unloaded int;
begin
    insert into silver.etl_run (brand_key) values ('(category_market)') returning run_id into v_run;

    drop table if exists _unloaded;
    create temp table _unloaded on commit drop as
    select cs.platform, cs.l1_id, cs.l2_id
    from silver.category_scope cs
    where cs.is_enabled
      and not exists (select 1 from silver.fact_shelf_position f
                       where f.platform = cs.platform and f.l1_id = cs.l1_id and f.l2_id = cs.l2_id);
    select count(*) into v_unloaded from _unloaded;

    if not p_full then
        select coalesce(greatest(last_seen_id - v_lb, 0), 0) into w_sp
          from silver.pipeline_source where source_schema = 'public' and source_table = 'shelf_positions';
    end if;
    v_start := case when p_full or v_unloaded > 0 then 0 else w_sp end;
    select coalesce(max(id), 0) into v_max from public.shelf_positions;

    insert into silver.dim_city (city_slug, city_name, state, center_lat, center_lon)
    select c.slug, c.name, c.state, c.center_lat, c.center_lon from public.cities c
    on conflict (city_slug) do update set
        city_name = excluded.city_name, state = excluded.state,
        center_lat = excluded.center_lat, center_lon = excluded.center_lon;

    v_lo := v_start;
    while v_lo < v_max loop
        v_hi := v_lo + v_step;

        with ins as (
            insert into silver.dim_store (platform, store_external_id, source_store_id, store_name, city_slug,
                                          latitude, longitude, first_seen_at, last_seen_at)
            select s.platform, s.external_id, s.id, s.name, s.city_slug, s.lat, s.lon, s.first_seen_at, s.last_seen_at
            from public.stores s
            where s.id in (
                    select distinct coalesce(sp.store_id, sn.store_id)
                    from public.shelf_positions sp
                    join public.shelf_snapshots sn on sn.id = sp.snapshot_id
                    join silver.category_scope cs on cs.platform = sn.platform and cs.l1_id = sn.l1_id
                                                 and cs.l2_id = sn.l2_id and cs.is_enabled
                    where sp.id > v_lo and sp.id <= v_hi and sn.status = 'ok'
                      and (sp.id > w_sp or (sn.platform, sn.l1_id, sn.l2_id) in (select platform, l1_id, l2_id from _unloaded)))
              and s.platform in (select platform from silver.dim_platform)
            on conflict (source_store_id) do nothing
            returning 1)
        select count(*) into v_new_stores from ins;
        v_tot_stores := v_tot_stores + v_new_stores;

        with src as materialized (
            select sp.id, sp.snapshot_id, sn.platform, sn.l1_id, sn.l2_id, coalesce(sp.store_id, sn.store_id) as src_store,
                   sn.taken_at, sp."position" as pos, sp.organic_position as opos, sp.is_ad, sp.ad_type, sp.brand,
                   sp.external_id, sp.name, sp.pack, sp.state, sp.inventory, sp.inventory_capped,
                   sp.price::numeric as price, sp.mrp::numeric as mrp,
                   sn.cards_seen, sn.total_items, sn.complete
            from public.shelf_positions sp
            join public.shelf_snapshots sn on sn.id = sp.snapshot_id
            join silver.category_scope cs on cs.platform = sn.platform and cs.l1_id = sn.l1_id
                                         and cs.l2_id = sn.l2_id and cs.is_enabled
            join silver.dim_platform dpl on dpl.platform = sn.platform and not dpl.is_test
            where sp.id > v_lo and sp.id <= v_hi and sn.status = 'ok'
              and (sp.id > w_sp or (sn.platform, sn.l1_id, sn.l2_id) in (select platform, l1_id, l2_id from _unloaded))
        ), bm as materialized (
            select x.b as raw_brand,
                   (select sb.brand_key from silver.brand_scope sb
                     where sb.is_enabled and silver.brand_matches(sb.brand_key, x.b)
                     order by sb.brand_key limit 1) as client_key
            from (select distinct brand as b from src where brand is not null) x
            offset 0
        ), ins as (
            insert into silver.fact_shelf_position (
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
                   s.cards_seen, s.total_items, s.complete, silver.dq_status(q.flags), q.flags, v_run
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
            returning (xmax = 0) as inserted)
        select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;
        v_tot_ins := v_tot_ins + v_ins; v_tot_upd := v_tot_upd + v_upd;

        v_p := silver.refresh_category_products(v_run, v_lo, v_hi);
        v_pb := v_pb + (v_p ->> 'brands')::int; v_pi := v_pi + (v_p ->> 'ins')::int;
        v_pu := v_pu + (v_p ->> 'upd')::int;    v_pl := v_pl + (v_p ->> 'linked')::int;

        v_lo := v_hi;
    end loop;

    v_stats := v_stats || jsonb_build_object(
        'mode', case when p_full then 'full' when v_unloaded > 0 then 'new_category' else 'incremental' end,
        'dim_store_added', v_tot_stores,
        'fact_shelf_position', jsonb_build_object('inserted', v_tot_ins, 'updated', v_tot_upd),
        'dim_brand_added', v_pb,
        'dim_product', jsonb_build_object('inserted', v_pi, 'updated', v_pu),
        'shelf_rows_linked', v_pl, 'run_id', v_run);
    update silver.etl_run set finished_at = now(), status = 'success', stats = v_stats where run_id = v_run;
    return v_stats;
end
$function$;
