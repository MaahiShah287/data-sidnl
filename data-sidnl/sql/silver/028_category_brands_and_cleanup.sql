-- Applied to Supabase as migration 20261107182010 (silver_028_category_brands_and_cleanup).
-- Exported from supabase_migrations.schema_migrations.

-- the team's silver already has (empty) tables for these inputs; drop the duplicate placeholder columns added in 026
alter table silver.fact_shelf_position drop column if exists "units_sold (units sold per SKU, store and day)";
alter table silver.dim_product
    drop column if exists "unit_cost (cost per unit, state tax basis)",
    drop column if exists "expiry_date (expiry date per batch)",
    drop column if exists "inventory_be (warehouse stock per SKU)",
    drop column if exists "target_sku (client confirms whether this SKU is a target SKU)",
    drop column if exists "price_threshold (target selling price per SKU)";

alter table silver.brand_scope add column if not exists scope_source text not null default 'client';
comment on column silver.brand_scope.scope_source is 'client = brand we report on (enabled); category_shelf = competitor brand seen on a scoped category shelf (disabled, only anchors dim_brand / SI ids)';

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
        insert into silver.brand_scope (brand_key, brand_name, company_name, raw_brand_aliases, scope_source)
        select c.brand_key, c.brand_name, c.company_name, array[c.brand_name], 'client'
        from cand c
        where not exists (select 1 from silver.brand_scope s where s.brand_key = c.brand_key and s.scope_source = 'client')
          and exists (select 1 from silver.brand_string_registry r
                      where replace(silver.norm_key(r.raw_brand), ' ', '') = replace(c.brand_key, ' ', ''))
        on conflict (brand_key) do update set
            is_enabled = true, scope_source = 'client', brand_name = excluded.brand_name,
            company_name = excluded.company_name
        returning brand_key)
    select coalesce(array_agg(brand_key), '{}') into v from ins;
    return v;
end $$;

create or replace function silver.refresh_category_products(p_run bigint)
returns jsonb
language plpgsql
set search_path to 'silver', 'public', 'pg_temp'
as $function$
declare v_b int; v_ins int; v_upd int; v_k int;
begin
    drop table if exists _cp_rows, _cp;

    create temp table _cp_rows on commit drop as
    select f.source_record_id, f.platform, f.platform_product_id, f.l1_id, f.l2_id, f.brand_key, f.brand_raw,
           f.product_name, f.pack_raw, f.observed_at, sp.ptype, sp.image_url
    from silver.fact_shelf_position f
    join public.shelf_positions sp on sp.id = f.source_record_id
    where f.etl_run_id = p_run and f.platform_product_id is not null;

    create temp table _cp_brand on commit drop as
    select distinct on (brand_key) brand_key, brand_raw
      from (select brand_key, brand_raw, count(*) n from _cp_rows where brand_key is not null group by 1, 2) z
     order by brand_key, n desc, brand_raw;

    -- competitor brands: registered in brand_scope but disabled (not re-parsed one by one)
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
