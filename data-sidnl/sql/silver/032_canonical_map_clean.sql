-- =============================================================================
-- File:    silver/032_canonical_map_clean.sql
-- Purpose: Clean the canonical product map.
--   1. Categories: use the deepest scraped category (listing breadcrumb L1>L2>L3) instead of the
--      shelf's L1>L2 only; null stays only where the scrapers captured nothing.
--   2. One product = one SI id, also when a platform lists the same product under two ids:
--      exact (brand + normalised name + normalised pack) match maps to the existing SI id.
--   3. Fuzzy matches no longer auto-merge (the scorer gives 1.0 to different flavours); they go
--      to silver.match_review_queue. Switch back with sidnl_config.auto_merge_fuzzy = 1.
--   4. Readable views: silver.v_canonical_product_map, silver.v_canonical_brand_summary.
-- =============================================================================

insert into silver.sidnl_config (key, value_num, description)
values ('auto_merge_fuzzy', 0,
        '1 = score >= th_auto merges automatically; 0 (default) = only exact brand+name+pack matches merge, fuzzy matches go to match_review_queue')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 1. Categories
-- ---------------------------------------------------------------------------
create or replace function silver.enrich_product_categories()
returns integer language plpgsql set search_path = silver, public, pg_temp as $$
declare n1 int; n2 int;
begin
    -- every breadcrumb the scrapers captured on a product page becomes a dim_category row
    insert into silver.dim_category (platform, l1_id, l1_name, l2_id, l2_name, l3_id, l3_name)
    select distinct l.platform, c -> 0 ->> 'id', c -> 0 ->> 'name', c -> 1 ->> 'id', c -> 1 ->> 'name',
                    c -> 2 ->> 'id', c -> 2 ->> 'name'
    from public.platform_listings l
    cross join lateral (select l.categories::jsonb as c) x
    where jsonb_typeof(c) = 'array' and jsonb_array_length(c) >= 1 and (c -> 0 ->> 'name') is not null
      and l.platform in (select platform from silver.dim_platform where not is_test)
    on conflict do nothing;

    -- a product takes the deepest category known for it (breadcrumb beats shelf L1>L2)
    with best as (
        select distinct on (d.product_key) d.product_key, dc.category_key,
               case when dc.l3_name is not null then 3 when dc.l2_name is not null then 2 else 1 end as depth
        from silver.dim_product d
        join public.platform_listings l on l.platform = d.platform and l.external_id = d.platform_product_id
        cross join lateral (select l.categories::jsonb as c) x
        join silver.dim_category dc
          on dc.platform = l.platform
         and dc.l1_id is not distinct from c -> 0 ->> 'id' and dc.l1_name is not distinct from c -> 0 ->> 'name'
         and dc.l2_id is not distinct from c -> 1 ->> 'id' and dc.l2_name is not distinct from c -> 1 ->> 'name'
         and dc.l3_id is not distinct from c -> 2 ->> 'id' and dc.l3_name is not distinct from c -> 2 ->> 'name'
        where jsonb_typeof(c) = 'array' and jsonb_array_length(c) >= 1
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

    -- products still without a category: use the shelf they were read on (L1>L2)
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

-- ---------------------------------------------------------------------------
-- 2. Exact key + mapping rule + one-off clean-up of existing duplicates
-- ---------------------------------------------------------------------------
create or replace function silver.exact_key(p_name text, p_pack text)
returns text language sql immutable as $$
    select regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', '', 'g') || '|' ||
           regexp_replace(lower(coalesce(p_pack, '')), '[^a-z0-9+]+', '', 'g')
$$;
comment on function silver.exact_key(text, text) is
    'Normalised name + pack. Two listings of one brand with the same key are the same product (any platform).';

create or replace function silver.merge_exact_duplicates(p_by text default session_user)
returns integer language plpgsql set search_path = silver, public, pg_temp as $$
declare n int;
begin
    drop table if exists _dup;
    create temp table _dup on commit drop as
    with m as (
        select x.sidnl_id, c.brand_key, silver.exact_key(d.product_name, d.pack_raw) k
        from silver.product_xref x
        join silver.dim_product d on d.product_key = x.product_key
        join silver.canonical_product c on c.sidnl_id = x.sidnl_id and c.is_active),
    g as (
        select brand_key, k, array_agg(distinct sidnl_id) as ids
        from m group by brand_key, k having count(distinct sidnl_id) > 1)
    select loser, (select i from unnest(g.ids) i order by length(i), i limit 1) as keeper
    from g cross join lateral unnest(g.ids) loser;
    delete from _dup where loser = keeper;

    update silver.product_xref x set
        sidnl_id = d.keeper, match_status = 'MAPPED', match_method = 'EXACT_NAME_PACK',
        score = 1, reviewed_by = p_by, reviewed_at = now()
    from _dup d where x.sidnl_id = d.loser;

    update silver.canonical_product c set is_active = false, merged_into = d.keeper
    from _dup d where c.sidnl_id = d.loser;
    get diagnostics n = row_count;

    delete from silver.match_review_queue q using _dup d
    where q.status = 'pending' and q.suggested_sidnl_id = d.loser;
    return n;
end $$;
comment on function silver.merge_exact_duplicates(text) is
    'Collapses SI ids whose products have the same brand + normalised name + normalised pack into the oldest SI id.';

create or replace function silver.map_product(p_product_key integer)
returns text language plpgsql set search_path = silver, public, extensions, pg_temp as $$
declare
    p silver.dim_product%rowtype;
    f silver.match_feat;
    th_auto numeric := silver.cfg('th_auto');  th_rev numeric := silver.cfg('th_review');
    v_fuzzy boolean := coalesce(silver.cfg('auto_merge_fuzzy'), 0) = 1;
    v_sid text; v_status text; v_method text; v_score numeric := 1; v_detail jsonb := '{}'::jsonb;
    b record;
begin
    select * into p from silver.dim_product where product_key = p_product_key;
    if not found then raise exception 'unknown product_key %', p_product_key; end if;

    select sidnl_id into v_sid from silver.product_xref where product_key = p_product_key;
    if found then return v_sid; end if;

    perform pg_advisory_xact_lock(727102);
    f := silver.features_of(p_product_key);

    -- 1. client catalog link on another platform
    if p.catalog_product_id is not null then
        select x.sidnl_id into v_sid
        from silver.product_xref x
        join silver.dim_product d on d.product_key = x.product_key
        where d.catalog_product_id = p.catalog_product_id
          and d.platform <> p.platform
          and not exists (select 1 from silver.product_xref x2
                          join silver.dim_product d2 on d2.product_key = x2.product_key
                          where x2.sidnl_id = x.sidnl_id and d2.platform = p.platform)
        order by x.matched_at, x.sidnl_id limit 1;
        if v_sid is not null then
            v_status := 'MAPPED'; v_method := 'CATALOG_LINK';
            v_detail := jsonb_build_object('catalog_product_id', p.catalog_product_id);
        end if;
    end if;

    -- 2. exact brand + name + pack (same or another platform)
    if v_sid is null then
        select x.sidnl_id into v_sid
        from silver.product_xref x
        join silver.canonical_product c on c.sidnl_id = x.sidnl_id and c.is_active
        join silver.dim_product d on d.product_key = x.product_key
        where c.brand_key = p.brand_key
          and silver.exact_key(d.product_name, d.pack_raw) = silver.exact_key(p.product_name, p.pack_raw)
        order by length(x.sidnl_id), x.sidnl_id limit 1;
        if v_sid is not null then
            v_status := 'MAPPED'; v_method := 'EXACT_NAME_PACK';
            v_detail := jsonb_build_object('rule', 'same brand + normalised name + normalised pack');
        end if;
    end if;

    -- 3. fuzzy: merge only when auto_merge_fuzzy = 1, otherwise ask a human
    if v_sid is null then
        select c.sidnl_id as cand, s.* into b
        from silver.canonical_product c
        cross join lateral silver.score_pair(f, silver.canon_feat(c)) s
        where c.brand_key = p.brand_key and c.is_active and c.pack_count = coalesce(p.pack_count, 1)
          and not exists (select 1 from silver.product_xref x
                          join silver.dim_product d on d.product_key = x.product_key
                          where x.sidnl_id = c.sidnl_id and d.platform = p.platform)
        order by s.score desc, c.sidnl_id
        limit 1;

        if b.cand is not null then
            v_score  := b.score;
            v_detail := jsonb_build_object('candidate', b.cand, 'name', b.name_sim, 'brand', b.brand_sim,
                                           'size', b.size_sim, 'variant', b.variant_sim, 'category', b.category_sim,
                                           'rules', b.rule_reason);
        end if;

        if v_fuzzy and b.cand is not null and b.score >= th_auto and b.rule_ok then
            v_sid := b.cand; v_status := 'MAPPED'; v_method := 'ATTRIBUTE_AUTO';
        else
            v_sid := silver.new_canonical(p_product_key);
            if b.cand is not null and b.score >= th_rev then
                v_status := 'PENDING_REVIEW'; v_method := 'ATTRIBUTE_REVIEW';
                insert into silver.match_review_queue (product_key, suggested_sidnl_id, score, rule_ok, rule_reason, score_detail)
                values (p_product_key, b.cand, b.score, b.rule_ok, b.rule_reason, v_detail)
                on conflict (product_key, suggested_sidnl_id) do nothing;
            else
                v_status := 'NEW_MASTER'; v_method := 'NEW_MASTER';
                v_score := 1; v_detail := v_detail || jsonb_build_object('best_rejected_score', b.score);
            end if;
        end if;
    end if;

    insert into silver.product_xref (product_key, sidnl_id, match_status, match_method, score, score_detail)
    values (p_product_key, v_sid, v_status, v_method, v_score, v_detail);
    return v_sid;
end $$;

create or replace function silver.sync_canonical_attrs()
returns integer language plpgsql set search_path = silver, public, extensions, pg_temp as $$
declare n int;
begin
    perform silver.enrich_product_categories();
    with x as (
        select c.sidnl_id, d.product_name, d.variant, d.product_type, d.size_value, d.size_unit,
               coalesce(d.pack_count, 1) pack_count, silver.features_of(c.anchor_product_key) f
        from silver.canonical_product c
        join silver.dim_product d on d.product_key = c.anchor_product_key
        where c.is_active)
    update silver.canonical_product c set
        canonical_name = x.product_name, name_clean = (x.f).name_clean, variant = x.variant,
        variant_key = (x.f).variant_key, product_type = x.product_type, size_value = x.size_value,
        size_unit = x.size_unit, pack_count = x.pack_count,
        category_l1 = (x.f).cat_l1, category_l2 = (x.f).cat_l2, category_l3 = (x.f).cat_l3
    from x
    where x.sidnl_id = c.sidnl_id
      and (c.canonical_name, c.name_clean, c.variant, c.variant_key, c.product_type, c.size_value, c.size_unit,
           c.pack_count, c.category_l1, c.category_l2, c.category_l3)
          is distinct from
          (x.product_name, (x.f).name_clean, x.variant, (x.f).variant_key, x.product_type, x.size_value, x.size_unit,
           x.pack_count, (x.f).cat_l1, (x.f).cat_l2, (x.f).cat_l3);
    get diagnostics n = row_count;
    return n;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Views
-- ---------------------------------------------------------------------------
-- an SI id can now hold more than one id on a platform: platform_ids keeps the oldest id per
-- platform (as before), platform_id_aliases lists every id.
create or replace view silver.v_sidnl_product with (security_invoker = true) as
with mem as (
    select c.sidnl_id, d.platform, d.platform_product_id, d.product_key, d.first_seen_at, d.last_seen_at, x.match_status
    from silver.canonical_product c
    join silver.product_xref x on x.sidnl_id = c.sidnl_id
    join silver.dim_product d on d.product_key = x.product_key
    where c.is_active),
per as (
    select sidnl_id, platform, min(platform_product_id) as primary_id,
           to_jsonb(array_agg(platform_product_id order by platform_product_id)) as all_ids
    from mem group by sidnl_id, platform),
pj as (
    select sidnl_id, jsonb_object_agg(platform, primary_id) as platform_ids,
           jsonb_object_agg(platform, all_ids) as platform_id_aliases
    from per group by sidnl_id),
agg as (
    select sidnl_id, count(*) as products, count(distinct platform) as platform_count,
           array_agg(product_key order by platform, product_key) as product_keys,
           bool_or(match_status = 'PENDING_REVIEW') as needs_review,
           min(first_seen_at) as first_seen_at, max(last_seen_at) as last_seen_at
    from mem group by sidnl_id)
select c.sidnl_id, c.brand_key, c.canonical_name, c.variant, c.size_value, c.size_unit, c.pack_count,
       c.category_l1, c.category_l2, c.category_l3,
       a.products, a.platform_count, pj.platform_ids, a.product_keys, a.needs_review,
       a.first_seen_at, a.last_seen_at, pj.platform_id_aliases
from silver.canonical_product c
join agg a on a.sidnl_id = c.sidnl_id
join pj on pj.sidnl_id = c.sidnl_id
where c.is_active;
comment on view silver.v_sidnl_product is 'One row per SI id: canonical attributes plus the product id on every platform (platform_id_aliases = all ids).';

create or replace view silver.v_canonical_product_map with (security_invoker = true) as
select c.sidnl_id,
       coalesce(b.brand_name, c.brand_key)         as brand,
       c.canonical_name                            as product_name,
       c.variant,
       c.product_type,
       trim_scale(c.size_value)                    as size_value,
       c.size_unit,
       c.pack_count,
       cat.l1_name                                 as category_l1,
       cat.l2_name                                 as category_l2,
       cat.l3_name                                 as category_l3,
       m.platforms,
       m.platform_count,
       m.platform_ids,
       m.listings                                  as platform_listings,
       m.image_url,
       m.first_seen_at,
       m.last_seen_at,
       m.needs_review
from silver.canonical_product c
left join silver.dim_brand b on b.brand_key = c.brand_key
left join lateral (
    select array_agg(distinct d.platform order by d.platform)    as platforms,
           count(distinct d.platform)                            as platform_count,
           count(*)                                              as listings,
           (select jsonb_object_agg(z.platform, z.ids)
              from (select d2.platform, to_jsonb(array_agg(d2.platform_product_id order by d2.platform_product_id)) as ids
                      from silver.product_xref x2 join silver.dim_product d2 on d2.product_key = x2.product_key
                     where x2.sidnl_id = c.sidnl_id group by d2.platform) z) as platform_ids,
           (array_agg(d.image_url order by (d.image_url is null), d.product_key))[1] as image_url,
           min(d.first_seen_at) as first_seen_at, max(d.last_seen_at) as last_seen_at,
           bool_or(x.match_status = 'PENDING_REVIEW') as needs_review
    from silver.product_xref x join silver.dim_product d on d.product_key = x.product_key
    where x.sidnl_id = c.sidnl_id) m on true
left join lateral (
    select dc.l1_name, dc.l2_name, dc.l3_name
    from silver.product_xref x join silver.dim_product d on d.product_key = x.product_key
    join silver.dim_category dc on dc.category_key = d.category_key
    where x.sidnl_id = c.sidnl_id
    order by (dc.l3_name is not null) desc, (dc.l2_name is not null) desc, d.product_key
    limit 1) cat on true
where c.is_active;
comment on view silver.v_canonical_product_map is
    'Readable canonical product map: one row per real product (SI id) with display category names. A column is NULL only when the scrapers captured nothing for it.';

create or replace view silver.v_canonical_brand_summary with (security_invoker = true) as
select brand, count(*) as products, sum(platform_listings) as platform_listings,
       count(*) filter (where platform_count > 1) as on_multiple_platforms,
       count(*) filter (where category_l3 is not null) as with_l3_category,
       count(*) filter (where needs_review) as needing_review
from silver.v_canonical_product_map
group by brand;
comment on view silver.v_canonical_brand_summary is 'One row per brand: how many distinct products (SI ids) it has. A brand repeats in the product map once per SKU by design; use this view for brand-level counts.';
