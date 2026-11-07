-- Applied to Supabase as migration 20261107183158 (silver_030_bronze_platform_products).
-- Exported from supabase_migrations.schema_migrations.

-- The team moved product attributes (name, brand, pack, ptype, image_url) out of
-- public.search_cards / public.shelf_positions into public.platform_products
-- (platform, external_id). Point the silver loaders at the new source.

create or replace function silver.refresh_brand_strings(p_full boolean default false)
returns integer
language plpgsql
set search_path to 'silver', 'public', 'pg_temp'
as $function$
declare v_n int := 0; v_c int;
begin
    insert into silver.brand_string_registry (raw_brand)
    select distinct brand::text from public.platform_products where brand is not null
    on conflict do nothing;
    get diagnostics v_c = row_count; v_n := v_n + v_c;

    insert into silver.brand_string_registry (raw_brand)
    select distinct brand::text from public.platform_listings where brand is not null
    on conflict do nothing;
    get diagnostics v_c = row_count; v_n := v_n + v_c;

    insert into silver.brand_string_registry (raw_brand)
    select distinct brand::text from public.products where brand is not null
    on conflict do nothing;
    get diagnostics v_c = row_count;
    return v_n + v_c;
end $function$;

do $do$
declare d text; d2 text;
begin
    -- refresh_brand
    d := pg_get_functiondef('silver.refresh_brand(text,boolean)'::regprocedure);
    d2 := replace(d, E'c.ptype, c.name, c.brand, c.pack, c.image_url\n    from public.search_cards c\n    join public.search_snapshots ss on ss.id = c.snapshot_id\n    where c.id > w_sc\n      and c.brand in (select b from _brand_strings)',
                     E'pp.ptype, pp.name, pp.brand, pp.pack, pp.image_url\n    from public.search_cards c\n    join public.search_snapshots ss on ss.id = c.snapshot_id\n    join public.platform_products pp on pp.platform = ss.platform and pp.external_id = c.external_id\n    where c.id > w_sc\n      and pp.brand in (select b from _brand_strings)');
    if d2 = d then raise exception 'refresh_brand search_cards patch did not apply'; end if;
    d := d2;
    d2 := replace(d, E'sp.ptype, sp.name, sp.brand, sp.pack, sp.image_url\n    from public.shelf_positions sp\n    join public.shelf_snapshots sn on sn.id = sp.snapshot_id\n    where sp.id > w_sp\n      and sp.brand in (select b from _brand_strings)',
                     E'pp.ptype, pp.name, pp.brand, pp.pack, pp.image_url\n    from public.shelf_positions sp\n    join public.shelf_snapshots sn on sn.id = sp.snapshot_id\n    join public.platform_products pp on pp.platform = sn.platform and pp.external_id = sp.external_id\n    where sp.id > w_sp\n      and pp.brand in (select b from _brand_strings)');
    if d2 = d then raise exception 'refresh_brand shelf patch did not apply'; end if;
    execute d2;

    -- refresh_category_market
    d := pg_get_functiondef('silver.refresh_category_market(boolean)'::regprocedure);
    d2 := replace(d, 'join silver.dim_platform dpl on', E'left join public.platform_products pp on pp.platform = sn.platform and pp.external_id = sp.external_id\n            join silver.dim_platform dpl on');
    d2 := replace(d2, 'sp.brand,', 'pp.brand,');
    d2 := replace(d2, 'sp.name, sp.pack,', 'pp.name, pp.pack,');
    if d2 = d or d2 like '%sp.brand%' or d2 like '%sp.name%' then raise exception 'refresh_category_market patch did not apply'; end if;
    execute d2;

    -- refresh_category_products
    d := pg_get_functiondef('silver.refresh_category_products(bigint,bigint,bigint)'::regprocedure);
    d2 := replace(d, 'sp.ptype, sp.image_url', 'pp.ptype, pp.image_url');
    d2 := replace(d2, 'join public.shelf_positions sp on sp.id = f.source_record_id',
                      'left join public.platform_products pp on pp.platform = f.platform and pp.external_id = f.platform_product_id');
    if d2 = d or d2 like '%sp.ptype%' or d2 like '%shelf_positions sp%' then raise exception 'refresh_category_products patch did not apply'; end if;
    execute d2;
end
$do$;

-- the registry no longer needs per-table watermarks for the card tables
update silver.pipeline_source set registry_last_id = 0 where source_table in ('search_cards','shelf_positions');
