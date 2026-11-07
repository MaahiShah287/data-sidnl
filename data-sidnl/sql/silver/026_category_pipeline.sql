-- Applied to Supabase as migration 20261107180938 (silver_026_category_pipeline).
-- Exported from supabase_migrations.schema_migrations.

create or replace function silver.register_category_scopes()
returns text[] language plpgsql set search_path = silver, public, pg_temp as $$
declare v text[];
begin
    with done as (
        select distinct cs.platform::text platform, cs.l1_id::text l1_id, cs.l2_id::text l2_id
        from public.category_sweeps cs
        where cs.status = 'done' and cs.stores_done >= 10
          and cs.platform::text in (select platform from silver.dim_platform where not is_test)),
    ins as (
        insert into silver.category_scope (platform, l1_id, l2_id, l1_name, l2_name)
        select d.platform, d.l1_id, d.l2_id,
               (select max(c.category_l1) from analytics.categories c
                 where c.platform::text = d.platform and c.category_l1_id::text = d.l1_id),
               (select max(c.category_l2) from analytics.categories c
                 where c.platform::text = d.platform and c.category_l1_id::text = d.l1_id and c.category_l2_id::text = d.l2_id)
        from done d
        where not exists (select 1 from silver.category_scope s
                           where s.platform = d.platform and s.l1_id = d.l1_id and s.l2_id = d.l2_id)
        returning platform || ':' || l1_id || '/' || l2_id as k)
    select coalesce(array_agg(k), '{}') into v from ins;
    return v;
end $$;
comment on function silver.register_category_scopes() is 'Finished category sweeps (status done, >= 10 stores) enter category_scope automatically.';

alter table silver.fact_shelf_position
    add column if not exists product_key int references silver.dim_product (product_key),
    add column if not exists "units_sold (units sold per SKU, store and day)" numeric;

alter table silver.dim_product
    add column if not exists "unit_cost (cost per unit, state tax basis)" numeric,
    add column if not exists "expiry_date (expiry date per batch)" date,
    add column if not exists "inventory_be (warehouse stock per SKU)" numeric,
    add column if not exists "target_sku (client confirms whether this SKU is a target SKU)" boolean,
    add column if not exists "price_threshold (target selling price per SKU)" numeric;

alter table silver.dim_store
    add column if not exists "store_weight (weight per store, e.g. store sales)" numeric;

create index if not exists ix_fsp_etl_run     on silver.fact_shelf_position (etl_run_id);
create index if not exists ix_fsp_product_key on silver.fact_shelf_position (product_key) where product_key is not null;
create index if not exists ix_fsp_platform_pid on silver.fact_shelf_position (platform, platform_product_id);

insert into silver.sidnl_config (key, value_num, description) values
    ('category_chunk_rows', 100000, 'refresh_category_market reads bronze shelf cards in id chunks of this size')
on conflict (key) do nothing;

drop function if exists silver.refresh_category_market();

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

        with src as (
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
        ), bm as (
            select x.b as raw_brand,
                   (select sb.brand_key from silver.brand_scope sb
                     where sb.is_enabled and silver.brand_matches(sb.brand_key, x.b)
                     order by sb.brand_key limit 1) as client_key
            from (select distinct brand as b from src where brand is not null) x
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
comment on function silver.refresh_category_market(boolean) is 'Category shelf cards -> fact_shelf_position (+ products via refresh_category_products). Incremental; a new category is loaded in full.';

create or replace function silver.refresh_category_products(p_run bigint)
returns jsonb
language plpgsql
set search_path to 'silver', 'public', 'pg_temp'
as $function$
declare v_b int; v_c int; v_ins int; v_upd int; v_k int;
begin
    drop table if exists _cp_rows, _cp;

    create temp table _cp_rows on commit drop as
    select f.source_record_id, f.platform, f.platform_product_id, f.l1_id, f.l2_id, f.brand_key, f.brand_raw,
           f.product_name, f.pack_raw, f.observed_at, sp.ptype, sp.image_url
    from silver.fact_shelf_position f
    join public.shelf_positions sp on sp.id = f.source_record_id
    where f.etl_run_id = p_run and f.platform_product_id is not null;

    with ins as (
        insert into silver.dim_brand (brand_key, brand_name, company_name, is_tracked)
        select b.brand_key, b.brand_raw, null, false
        from (select distinct on (brand_key) brand_key, brand_raw
                from (select brand_key, brand_raw, count(*) n from _cp_rows where brand_key is not null group by 1, 2) z
               order by brand_key, n desc, brand_raw) b
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
     where f.etl_run_id = p_run and dp.platform = f.platform and dp.platform_product_id = f.platform_product_id
       and f.product_key is distinct from dp.product_key;
    get diagnostics v_k = row_count;

    update silver.dim_product p
       set first_seen_at = least(coalesce(p.first_seen_at, x.mn), x.mn),
           last_seen_at  = greatest(coalesce(p.last_seen_at, x.mx), x.mx)
      from (select platform, platform_product_id, min(observed_at) mn, max(observed_at) mx
              from _cp_rows group by 1, 2) x
     where p.platform = x.platform and p.platform_product_id = x.platform_product_id
       and (p.first_seen_at is null or p.last_seen_at is null or x.mn < p.first_seen_at or x.mx > p.last_seen_at);

    return jsonb_build_object('dim_brand_added', v_b, 'dim_product', jsonb_build_object('inserted', v_ins, 'updated', v_upd),
                              'shelf_rows_linked', v_k);
end
$function$;

create or replace view silver.v_category_shelf with (security_invoker = true) as
select x.sidnl_id, c.canonical_name, f.platform, f.brand_key, b.brand_name, dc.category_path,
       f.product_key, f.platform_product_id, f.product_name, f.pack_raw,
       ds.city_slug, ds.store_name, f.observed_at, f.obs_date,
       f.shelf_position, f.organic_position, f.is_ad, f.ad_type,
       f.stock_status, f.inventory_units, f.inventory_is_capped, f.selling_price, f.mrp, f.discount_pct,
       f.shelf_complete, f.dq_status
from silver.fact_shelf_position f
left join silver.product_xref x on x.product_key = f.product_key
left join silver.canonical_product c on c.sidnl_id = x.sidnl_id
left join silver.dim_brand b on b.brand_key = f.brand_key
left join silver.dim_store ds on ds.store_key = f.store_key
left join silver.dim_product dp on dp.product_key = f.product_key
left join silver.dim_category dc on dc.category_key = dp.category_key;
comment on view silver.v_category_shelf is 'Category shelf readings (all brands) with the SI id of the product.';

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
    v_tmp jsonb; v_plat text[]; v_brands text[]; v_cats text[]; v_full boolean; v_bad jsonb;
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

    begin
        v_plat := silver.register_platforms();
        v_cats := silver.register_category_scopes();
        perform silver.refresh_brand_strings(p_force);
        v_brands := silver.onboard_brands();
        v_steps := v_steps || jsonb_build_object('discover', jsonb_build_object(
            'ok', true, 'new_platforms', to_jsonb(v_plat), 'new_categories', to_jsonb(v_cats), 'new_brands', to_jsonb(v_brands)));
    exception when others then
        v_failed := true; v_plat := '{}';
        v_steps := v_steps || jsonb_build_object('discover', jsonb_build_object('ok', false, 'error', sqlerrm));
    end;
    v_full := p_force or coalesce(array_length(v_plat, 1), 0) > 0;

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
        v_tmp := silver.refresh_category_market(v_full);
        v_steps := v_steps || jsonb_build_object('refresh_category_market', jsonb_build_object(
            'ok', true, 'seconds', round(extract(epoch from clock_timestamp() - v_t)::numeric, 2), 'stats', v_tmp));
    exception when others then
        v_failed := true;
        v_steps := v_steps || jsonb_build_object('refresh_category_market', jsonb_build_object('ok', false, 'error', sqlerrm));
    end;

    begin
        v_steps := v_steps || jsonb_build_object('map_new_products', jsonb_build_object('ok', true, 'result', silver.map_new_products()));
        v_steps := v_steps || jsonb_build_object('sync_canonical_attrs', jsonb_build_object('ok', true, 'updated', silver.sync_canonical_attrs()));
    exception when others then
        v_failed := true;
        v_steps := v_steps || jsonb_build_object('canonical_map', jsonb_build_object('ok', false, 'error', sqlerrm));
    end;

    begin
        select jsonb_agg(jsonb_build_object('check', q.check_name, 'detail', q.detail)) into v_bad
          from silver.quality_checks() q where not q.ok;
        v_steps := v_steps || jsonb_build_object('quality_gate', jsonb_build_object('ok', v_bad is null, 'failed', v_bad));
    exception when others then
        v_steps := v_steps || jsonb_build_object('quality_gate', jsonb_build_object('ok', false, 'error', sqlerrm));
    end;

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
