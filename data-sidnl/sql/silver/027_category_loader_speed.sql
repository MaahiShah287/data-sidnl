-- Applied to Supabase as migration 20261107181510 (silver_027_category_loader_speed).
-- Exported from supabase_migrations.schema_migrations.

create or replace function silver.refresh_category_market(p_full boolean default false)
returns jsonb
language plpgsql
set search_path to 'silver', 'public', 'pg_temp'
as $function$
declare
    v_run bigint; v_ins int; v_upd int; v_new_stores int;
    v_tot_ins int := 0; v_tot_upd int := 0; v_tot_stores int := 0;
    v_stats jsonb := '{}'::jsonb;
    v_lb   bigint := coalesce(silver.cfg('incremental_lookback_rows'), 5000)::bigint;
    v_step bigint := coalesce(silver.cfg('category_chunk_rows'), 100000)::bigint;
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

        v_lo := v_hi;
    end loop;

    v_stats := v_stats || jsonb_build_object(
        'mode', case when p_full then 'full' when v_unloaded > 0 then 'new_category' else 'incremental' end,
        'dim_store_added', v_tot_stores,
        'fact_shelf_position', jsonb_build_object('inserted', v_tot_ins, 'updated', v_tot_upd));

    v_stats := v_stats || jsonb_build_object('products', silver.refresh_category_products(v_run));
    v_stats := v_stats || jsonb_build_object('run_id', v_run);
    update silver.etl_run set finished_at = now(), status = 'success', stats = v_stats where run_id = v_run;
    return v_stats;
end
$function$;

select cron.alter_job(1, command := $$set statement_timeout = '600s'; select silver.run_pipeline(false, 'cron')$$);
select cron.alter_job(2, command := $$set statement_timeout = '600s'; select silver.run_pipeline(true, 'cron-daily')$$);
