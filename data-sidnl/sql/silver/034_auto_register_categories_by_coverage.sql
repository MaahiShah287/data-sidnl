-- Applied to Supabase as migration silver_034_auto_register_categories_by_coverage.
-- A category shelf is loaded automatically once it has been read OK at >= category_min_stores distinct
-- dark stores, whether or not a scraper sweep was marked 'done'. Before, only 'done' sweeps counted,
-- so categories read by smaller or interrupted runs (e.g. Chips & Crisps) were never picked up.
insert into silver.sidnl_config (key, value_num, description)
values ('category_min_stores', 10,
        'A category shelf is auto-loaded into silver once it was read OK at this many distinct dark stores')
on conflict (key) do nothing;

create or replace function silver.register_category_scopes()
returns text[] language plpgsql set search_path = silver, public, pg_temp as $$
declare v text[]; v_min int := coalesce(silver.cfg('category_min_stores'), 10)::int;
begin
    with cov as (
        select sn.platform::text as platform, sn.l1_id::text as l1_id, sn.l2_id::text as l2_id
        from public.shelf_snapshots sn
        where sn.status = 'ok' and sn.l1_id is not null and sn.l2_id is not null
          and sn.platform::text in (select platform from silver.dim_platform where not is_test)
        group by 1, 2, 3
        having count(distinct sn.store_id) >= v_min
        union
        select cs.platform::text, cs.l1_id::text, cs.l2_id::text
        from public.category_sweeps cs
        where cs.status = 'done' and cs.stores_done >= v_min
          and cs.platform::text in (select platform from silver.dim_platform where not is_test)),
    ins as (
        insert into silver.category_scope (platform, l1_id, l2_id, l1_name, l2_name)
        select d.platform, d.l1_id, d.l2_id,
               (select max(c.category_l1) from analytics.categories c
                 where c.platform::text = d.platform and c.category_l1_id::text = d.l1_id),
               (select max(c.category_l2) from analytics.categories c
                 where c.platform::text = d.platform and c.category_l1_id::text = d.l1_id and c.category_l2_id::text = d.l2_id)
        from cov d
        where not exists (select 1 from silver.category_scope s
                           where s.platform = d.platform and s.l1_id = d.l1_id and s.l2_id = d.l2_id)
        returning platform || ':' || l1_id || '/' || l2_id as k)
    select coalesce(array_agg(k), '{}') into v from ins;
    return v;
end $$;
comment on function silver.register_category_scopes() is
    'Adds every category shelf read OK at >= category_min_stores stores (or by a done sweep of that size) to category_scope. Run by run_pipeline() on every tick.';
