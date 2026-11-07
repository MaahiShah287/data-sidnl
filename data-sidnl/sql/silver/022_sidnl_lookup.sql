-- =============================================================================
-- File:    silver/022_sidnl_lookup.sql
-- Purpose: "Search SI001, get everything."
--
--   select silver.sidnl_everything('SI001');          -- every table, every platform, as jsonb
--   select * from silver.sidnl_find('<name words>');   -- name / platform id / SI id -> SI ids
--   select * from silver.v_sidnl_product;              -- one row per product with its platform ids
--   select * from silver.v_reading_by_sidnl where sidnl_id = 'SI001';
-- =============================================================================

-- Follows merged_into so a retired SI id still finds its product.
create or replace function silver.sidnl_resolve(p_id text)
returns text language sql stable set search_path = silver, public, pg_temp as $$
    with recursive r(id, depth) as (
        select c.sidnl_id, 0 from silver.canonical_product c where c.sidnl_id = silver.sidnl_normalize(p_id)
        union all
        select c.merged_into, r.depth + 1
        from r join silver.canonical_product c on c.sidnl_id = r.id
        where c.merged_into is not null and r.depth < 10)
    select id from r order by depth desc limit 1
$$;

create or replace view silver.v_sidnl_product with (security_invoker = true) as
select c.sidnl_id, c.brand_key, c.canonical_name, c.variant, c.size_value, c.size_unit, c.pack_count,
       c.category_l1, c.category_l2, c.category_l3,
       count(*)                                      as products,
       count(distinct d.platform)                    as platform_count,
       jsonb_object_agg(d.platform, d.platform_product_id order by d.platform) as platform_ids,
       array_agg(d.product_key order by d.platform)  as product_keys,
       bool_or(x.match_status = 'PENDING_REVIEW')    as needs_review,
       min(d.first_seen_at)                          as first_seen_at,
       max(d.last_seen_at)                           as last_seen_at
from silver.canonical_product c
join silver.product_xref x on x.sidnl_id = c.sidnl_id
join silver.dim_product d on d.product_key = x.product_key
where c.is_active
group by c.sidnl_id, c.brand_key, c.canonical_name, c.variant, c.size_value, c.size_unit, c.pack_count,
         c.category_l1, c.category_l2, c.category_l3;
comment on view silver.v_sidnl_product is 'One row per SI id: canonical attributes plus the product id on every platform.';

create or replace view silver.v_dim_product_sidnl with (security_invoker = true) as
select x.sidnl_id, x.match_status, x.match_method, x.score, d.*
from silver.dim_product d
left join silver.product_xref x on x.product_key = d.product_key;

create or replace view silver.v_reading_by_sidnl with (security_invoker = true) as
select x.sidnl_id, r.*
from silver.product_xref x
join silver.v_reading r on r.product_key = x.product_key;
comment on view silver.v_reading_by_sidnl is 'v_reading with the SI id attached: filter by sidnl_id to read one product across platforms.';

-- ---------------------------------------------------------------------------
-- sidnl_find: lexical lookup. Accepts an SI id, a platform product id, or free text.
-- ---------------------------------------------------------------------------
create or replace function silver.sidnl_find(p_query text, p_limit int default 10)
returns table (sidnl_id text, canonical_name text, platform_ids jsonb, match_type text, similarity numeric)
language sql stable set search_path = silver, public, extensions, pg_temp as $$
    with q as (select btrim(p_query) raw, silver.sidnl_resolve(p_query) sid,
                      silver.clean_tokens(p_query, null) toks),
    hits as (
        select v.sidnl_id, 'sidnl_id'::text mt, 1.0::numeric sim
        from q join silver.v_sidnl_product v on v.sidnl_id = q.sid
        union all
        select x.sidnl_id, 'platform_product_id', 1.0
        from q join silver.dim_product d on d.platform_product_id = q.raw
        join silver.product_xref x on x.product_key = d.product_key
        union all
        select c.sidnl_id, 'name',
               greatest(similarity(c.name_clean, q.toks), case when c.canonical_name ilike '%' || q.raw || '%' then 0.8 else 0 end)::numeric
        from q join silver.canonical_product c on c.is_active
        where q.toks <> '' and (similarity(c.name_clean, q.toks) > 0.25 or c.canonical_name ilike '%' || q.raw || '%'))
    select v.sidnl_id, v.canonical_name, v.platform_ids, h.mt, round(h.sim, 3)
    from (select distinct on (sidnl_id) sidnl_id, mt, sim from hits order by sidnl_id, sim desc) h
    join silver.v_sidnl_product v on v.sidnl_id = h.sidnl_id
    order by h.sim desc, v.sidnl_id
    limit p_limit
$$;

-- ---------------------------------------------------------------------------
-- sidnl_everything: every row about this product, from every silver/gold table.
-- Tables are discovered from the catalog, so new fact/gold tables are picked up
-- automatically as long as they carry product_key, or platform + platform_product_id.
-- p_row_limit caps rows PER TABLE (row_count always shows the true total).
-- ---------------------------------------------------------------------------
create or replace function silver.sidnl_everything(p_id text, p_row_limit int default 1000)
returns jsonb language plpgsql stable set search_path = silver, public, extensions, pg_temp as $$
declare
    v_id   text := silver.sidnl_resolve(p_id);
    v_keys int[];
    t      record;
    v_rows jsonb; v_n bigint; v_where text;
    v_tables jsonb := '{}'::jsonb; v_skipped text[] := '{}'; v_empty int := 0;
begin
    if v_id is null then
        return jsonb_build_object('error', format('unknown SI id: %s', p_id));
    end if;
    select array_agg(product_key) into v_keys from silver.product_xref where sidnl_id = v_id;

    for t in
        select c.table_schema, c.table_name,
               bool_or(c.column_name = 'product_key')         as has_pk,
               bool_or(c.column_name = 'platform_product_id') as has_pid,
               bool_or(c.column_name = 'platform')            as has_platform
        from information_schema.columns c
        join information_schema.tables tb
          on tb.table_schema = c.table_schema and tb.table_name = c.table_name and tb.table_type = 'BASE TABLE'
        where c.table_schema in ('silver', 'gold')
          and c.column_name in ('product_key', 'platform_product_id', 'platform')
        group by c.table_schema, c.table_name
        having bool_or(c.column_name = 'product_key')
            or bool_or(c.column_name = 'platform_product_id')
        order by 1, 2
    loop
        if t.has_pk then
            v_where := 'product_key = any($1)';
        elsif t.has_pid and t.has_platform then
            v_where := '(platform, platform_product_id) in (select d.platform, d.platform_product_id from silver.dim_product d where d.product_key = any($1))';
        else
            v_skipped := v_skipped || (t.table_schema || '.' || t.table_name);
            continue;
        end if;

        execute format('select count(*) from %I.%I where %s', t.table_schema, t.table_name, v_where) into v_n using v_keys;
        if v_n = 0 then v_empty := v_empty + 1; continue; end if;
        execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from (select * from %I.%I where %s limit %s) x',
                       t.table_schema, t.table_name, v_where, greatest(p_row_limit, 1)) into v_rows using v_keys;
        v_tables := v_tables || jsonb_build_object(t.table_schema || '.' || t.table_name,
                        jsonb_build_object('row_count', v_n, 'truncated', v_n > p_row_limit, 'rows', v_rows));
    end loop;

    return jsonb_build_object(
        'sidnl_id', v_id,
        'canonical', (select to_jsonb(c) from silver.canonical_product c where c.sidnl_id = v_id),
        'members', (select coalesce(jsonb_agg(jsonb_build_object(
                        'product_key', d.product_key, 'platform', d.platform,
                        'platform_product_id', d.platform_product_id, 'product_name', d.product_name,
                        'pack_raw', d.pack_raw, 'match_status', x.match_status, 'match_method', x.match_method,
                        'score', x.score) order by d.platform), '[]'::jsonb)
                    from silver.product_xref x join silver.dim_product d on d.product_key = x.product_key
                    where x.sidnl_id = v_id),
        'tables', v_tables,
        'empty_tables_checked', v_empty,
        'skipped_tables_without_platform', to_jsonb(v_skipped));
end $$;
comment on function silver.sidnl_everything(text, int) is 'All rows for one SI id across every silver/gold table and platform, as jsonb.';
