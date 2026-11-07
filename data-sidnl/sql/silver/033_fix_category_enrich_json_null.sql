-- Applied to Supabase as migration 20261107184914 (silver_033_fix_category_enrich_json_null).
-- Exported from supabase_migrations.schema_migrations.

create or replace function silver.enrich_product_categories()
returns integer language plpgsql set search_path = silver, public, pg_temp as $$
declare n1 int; n2 int;
begin
    insert into silver.dim_category (platform, l1_id, l1_name, l2_id, l2_name, l3_id, l3_name)
    select distinct l.platform, c -> 0 ->> 'id', c -> 0 ->> 'name', c -> 1 ->> 'id', c -> 1 ->> 'name',
                    c -> 2 ->> 'id', c -> 2 ->> 'name'
    from public.platform_listings l
    cross join lateral (select case when jsonb_typeof(l.categories::jsonb) = 'array' then l.categories::jsonb end as c) x
    where c is not null and jsonb_array_length(c) >= 1 and (c -> 0 ->> 'name') is not null
      and l.platform in (select platform from silver.dim_platform where not is_test)
    on conflict do nothing;

    with best as (
        select distinct on (d.product_key) d.product_key, dc.category_key,
               case when dc.l3_name is not null then 3 when dc.l2_name is not null then 2 else 1 end as depth
        from silver.dim_product d
        join public.platform_listings l on l.platform = d.platform and l.external_id = d.platform_product_id
        cross join lateral (select case when jsonb_typeof(l.categories::jsonb) = 'array' then l.categories::jsonb end as c) x
        join silver.dim_category dc
          on dc.platform = l.platform
         and dc.l1_id is not distinct from c -> 0 ->> 'id' and dc.l1_name is not distinct from c -> 0 ->> 'name'
         and dc.l2_id is not distinct from c -> 1 ->> 'id' and dc.l2_name is not distinct from c -> 1 ->> 'name'
         and dc.l3_id is not distinct from c -> 2 ->> 'id' and dc.l3_name is not distinct from c -> 2 ->> 'name'
        where c is not null and jsonb_array_length(c) >= 1
        order by d.product_key, 3 desc, l.id desc)
    update silver.dim_product d set category_key = b.category_key
    from best b
    left join silver.dim_product d0 on d0.product_key = b.product_key
    left join silver.dim_category cur on cur.category_key = d0.category_key
    where d.product_key = b.product_key
      and d.category_key is distinct from b.category_key
      and b.depth > case when cur.l3_name is not null then 3 when cur.l2_name is not null then 2
                         when cur.l1_name is not null then 1 else 0 end;
    get diagnostics n1 = row_count;

    with s as (
        select distinct on (d.product_key) d.product_key, dc.category_key
        from silver.dim_product d
        join analytics.product_categories pc on pc.platform::text = d.platform and pc.product_id::text = d.platform_product_id
        join silver.dim_category dc on dc.platform = d.platform and dc.l1_id = pc.category_l1_id::text
                                   and dc.l2_id = pc.category_l2_id::text
        where d.category_key is null
        order by d.product_key, (dc.l3_id is null) desc, dc.category_key)
    update silver.dim_product d set category_key = s.category_key from s where d.product_key = s.product_key;
    get diagnostics n2 = row_count;
    return n1 + n2;
end $$;
comment on function silver.enrich_product_categories() is
    'Fills dim_product.category_key with the deepest scraped category (breadcrumb L1>L2>L3, else shelf L1>L2). Never invents a level.';
