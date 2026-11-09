-- DRAFT — NOT APPLIED. dash_004_gold_cleanup
-- After this, the dashboard data lives in the 6 dash.* tables. gold keeps only what dash needs:
--   8 lookup tables: dim_brand, dim_category, dim_city, dim_date, dim_platform, dim_product, dim_sidnl, dim_store
--   2 config tables: cfg_threshold, cfg_sku
--   1 view: v_valid_reading (the validated-reading input of dash.refresh)
-- Dropped: 111 gold tables (96 metric_* / per-metric and summary tables plus refresh_log/refresh_state),
--          14 gold views, gold.refresh_all / refresh_listing / refresh_visibility, and the whole gold_stage schema.
-- Everything dropped is derived from silver. It can be rebuilt from sql/gold/*.sql and the function
-- definitions saved below in ops.function_backup (tag 'pre_dash_004').
-- Safety: the migration aborts (and rolls back completely) if it would remove anything outside gold/gold_stage,
-- or if any kept object is missing at the end.

-- 0. Save every function and view definition this migration replaces or drops.
insert into ops.function_backup (fn, tag, definition, saved_at)
select p.pronamespace::regnamespace || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
       'pre_dash_004', pg_get_functiondef(p.oid), now()
from pg_proc p
where p.pronamespace in ('gold'::regnamespace, 'gold_stage'::regnamespace)
   or p.oid = 'silver.run_gold_pending'::regproc;
insert into ops.function_backup (fn, tag, definition, saved_at)
select 'view gold.' || c.relname, 'pre_dash_004',
       'create or replace view gold.' || quote_ident(c.relname) || ' as ' || pg_get_viewdef(c.oid), now()
from pg_class c
where c.relnamespace = 'gold'::regnamespace and c.relkind = 'v' and c.relname <> 'v_valid_reading';

-- 1. gold.sync_dims() takes over the two dimension jobs gold_stage.refresh_metrics() did:
--    dim_sidnl (product names for dash) and dim_brand.is_client.
create or replace function gold.sync_dims()
 returns void
 language plpgsql
 set search_path to 'gold', 'silver', 'public', 'pg_temp'
as $function$
begin
    insert into gold.dim_platform select platform from silver.dim_platform where not is_test on conflict do nothing;

    insert into gold.dim_city (city_slug, city_name, state)
        select city_slug, city_name, state from silver.dim_city
        on conflict (city_slug) do update set city_name = excluded.city_name, state = excluded.state
        where (gold.dim_city.city_name, gold.dim_city.state) is distinct from (excluded.city_name, excluded.state);
    insert into gold.dim_city values ('ALL', 'All cities', null), ('(unknown)', 'Unknown city', null) on conflict do nothing;

    insert into gold.dim_brand (brand_key, brand_name, company_name)
        select brand_key, brand_name, company_name from silver.dim_brand
        on conflict (brand_key) do update set brand_name = excluded.brand_name, company_name = excluded.company_name
        where (gold.dim_brand.brand_name, gold.dim_brand.company_name) is distinct from (excluded.brand_name, excluded.company_name);
    update gold.dim_brand b
       set is_client = exists (select 1 from silver.brand_scope s where s.brand_key = b.brand_key and s.is_enabled)
     where b.is_client is distinct from exists (select 1 from silver.brand_scope s where s.brand_key = b.brand_key and s.is_enabled);

    insert into gold.dim_category (platform, l1_id, l2_id, l1_name, l2_name)
        select platform, l1_id, l2_id, l1_name, l2_name from silver.category_scope
        on conflict (platform, l1_id, l2_id) do update set l1_name = excluded.l1_name, l2_name = excluded.l2_name
        where (gold.dim_category.l1_name, gold.dim_category.l2_name) is distinct from (excluded.l1_name, excluded.l2_name);

    insert into gold.dim_product (product_key, platform, platform_product_id, brand_key, product_name, variant, pack_raw, catalog_product_id, category_path, sidnl_id)
        select p.product_key, p.platform, p.platform_product_id, p.brand_key, p.product_name, p.variant, p.pack_raw, p.catalog_product_id, c.category_path, x.sidnl_id
        from silver.dim_product p
        left join silver.dim_category c on c.category_key = p.category_key
        left join silver.product_xref x on x.product_key = p.product_key
        where p.platform in (select platform from gold.dim_platform)
        on conflict (product_key) do update set product_name = excluded.product_name, variant = excluded.variant,
            pack_raw = excluded.pack_raw, catalog_product_id = excluded.catalog_product_id, category_path = excluded.category_path,
            sidnl_id = excluded.sidnl_id
        where (gold.dim_product.product_name, gold.dim_product.variant, gold.dim_product.pack_raw, gold.dim_product.catalog_product_id, gold.dim_product.category_path, gold.dim_product.sidnl_id)
              is distinct from (excluded.product_name, excluded.variant, excluded.pack_raw, excluded.catalog_product_id, excluded.category_path, excluded.sidnl_id);

    -- dim_sidnl: one row per SI id that has a gold product (same rule gold_stage used), upserted instead of delete+insert
    insert into gold.dim_sidnl (sidnl_id, brand_key, canonical_name, variant, size_value, size_unit, pack_count, category_path)
        select cp.sidnl_id, cp.brand_key, cp.canonical_name, cp.variant, cp.size_value, cp.size_unit, cp.pack_count,
               coalesce(nullif(concat_ws(' > ', cp.category_l1, cp.category_l2, cp.category_l3), ''),
                        (select max(gp.category_path) from gold.dim_product gp where gp.sidnl_id = cp.sidnl_id))
        from silver.canonical_product cp
        where exists (select 1 from gold.dim_product k where k.sidnl_id = cp.sidnl_id)
        on conflict (sidnl_id) do update set brand_key = excluded.brand_key, canonical_name = excluded.canonical_name,
            variant = excluded.variant, size_value = excluded.size_value, size_unit = excluded.size_unit,
            pack_count = excluded.pack_count, category_path = excluded.category_path
        where (gold.dim_sidnl.brand_key, gold.dim_sidnl.canonical_name, gold.dim_sidnl.variant, gold.dim_sidnl.size_value,
               gold.dim_sidnl.size_unit, gold.dim_sidnl.pack_count, gold.dim_sidnl.category_path)
              is distinct from (excluded.brand_key, excluded.canonical_name, excluded.variant, excluded.size_value,
               excluded.size_unit, excluded.pack_count, excluded.category_path);
    delete from gold.dim_sidnl d
     where not exists (select 1 from gold.dim_product k where k.sidnl_id = d.sidnl_id);

    insert into gold.dim_store (store_key, platform, store_name, city_slug)
        select store_key, platform, store_name, city_slug from silver.dim_store
        where platform in (select platform from gold.dim_platform)
        on conflict (store_key) do update set store_name = excluded.store_name, city_slug = excluded.city_slug
        where (gold.dim_store.store_name, gold.dim_store.city_slug) is distinct from (excluded.store_name, excluded.city_slug);
end $function$;

-- 2. The gold job now does only: sync lookups -> rebuild dash. A dash failure fails the run, so the
--    existing retry/backoff in ops.pipeline_run applies to it.
create or replace function silver.run_gold_pending()
 returns jsonb
 language plpgsql
 set search_path to 'silver', 'ops', 'public', 'gold', 'pg_temp'
 set statement_timeout to '600s'
as $function$
declare v record; v_t timestamptz; v_att int; v_dash jsonb;
begin
    if not pg_try_advisory_xact_lock(727101) then
        return jsonb_build_object('status', 'skipped', 'reason', 'gold refresh in progress');
    end if;
    select run_id, gold_status, gold_attempts into v from ops.pipeline_run
     where status = 'success' and (gold_status = 'pending' or (gold_status = 'failed' and gold_next_at <= now()))
     order by run_id desc limit 1;
    if not found then return jsonb_build_object('status', 'idle'); end if;
    update ops.pipeline_run set gold_status = 'superseded'
     where status = 'success' and gold_status = 'pending' and run_id < v.run_id;
    v_t := clock_timestamp();
    begin
        perform gold.sync_dims();
        v_dash := dash.refresh(3);
        update ops.pipeline_run set gold_status = 'success', gold_error = null, gold_next_at = null,
               gold_seconds = round(extract(epoch from clock_timestamp() - v_t)::numeric, 2) where run_id = v.run_id;
        return jsonb_build_object('status', 'success', 'run_id', v.run_id, 'dash', v_dash);
    exception when others then
        v_att := v.gold_attempts + 1;
        update ops.pipeline_run
           set gold_status = 'failed', gold_error = left(sqlerrm, 1000), gold_attempts = v_att,
               gold_seconds = round(extract(epoch from clock_timestamp() - v_t)::numeric, 2),
               gold_next_at = case when v_att < 5 and silver.classify_error(sqlstate) = 'transient'
                                   then now() + make_interval(mins => silver.backoff_minutes(v_att)) end
         where run_id = v.run_id;
        return jsonb_build_object('status', 'failed', 'run_id', v.run_id, 'error', sqlerrm, 'attempt', v_att);
    end;
end $function$;

-- 3. Drop the old gold layer, with guards.
do $cleanup$
declare
  v_keep text[] := array['dim_brand','dim_category','dim_city','dim_date','dim_platform','dim_product','dim_sidnl','dim_store',
                         'cfg_sku','cfg_threshold','v_valid_reading'];
  v_outside_before bigint; v_outside_after bigint; r record;
begin
  -- objects outside gold / gold_stage that must survive untouched
  select count(*) into v_outside_before from pg_class
   where relnamespace not in ('gold'::regnamespace, 'gold_stage'::regnamespace) and relkind in ('r','v','m','p')
     and relpersistence <> 't';

  drop function gold.refresh_all();
  drop function gold.refresh_listing(date);
  drop function gold.refresh_visibility(boolean);
  drop schema gold_stage cascade;

  for r in select c.relname from pg_class c
            where c.relnamespace = 'gold'::regnamespace and c.relkind = 'v' and not (c.relname = any(v_keep)) loop
    execute format('drop view if exists gold.%I cascade', r.relname);
  end loop;
  for r in select c.relname from pg_class c
            where c.relnamespace = 'gold'::regnamespace and c.relkind = 'r' and not (c.relname = any(v_keep)) loop
    execute format('drop table if exists gold.%I cascade', r.relname);
  end loop;

  select count(*) into v_outside_after from pg_class
   where relnamespace not in ('gold'::regnamespace) and relkind in ('r','v','m','p')
     and relpersistence <> 't';
  if v_outside_after <> v_outside_before then
    raise exception 'cleanup would remove % object(s) outside gold; aborting', v_outside_before - v_outside_after;
  end if;
  if (select count(*) from pg_class where relnamespace = 'gold'::regnamespace and relkind in ('r','v') and relname = any(v_keep)) <> 11 then
    raise exception 'a kept gold object is missing; aborting';
  end if;
  if (select count(*) from pg_class where relnamespace = 'gold'::regnamespace and relkind in ('r','v','m')) <> 11 then
    raise exception 'unexpected objects left in gold; aborting';
  end if;
  if (select count(*) from pg_class where relnamespace = 'dash'::regnamespace and relkind = 'r') <> 6 then
    raise exception 'dash tables missing; aborting';
  end if;
end $cleanup$;

comment on schema gold is 'Lookups (dim_*) and config (cfg_*) used by the dash tables, plus v_valid_reading. Dashboard data lives in schema dash.';
