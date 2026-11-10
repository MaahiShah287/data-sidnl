-- data-sidnl schema, part 2 of 3: every function in silver, dash and ops plus the public sidnl_* endpoint (exact text of pg_get_functiondef) and function permissions
-- GENERATED from the live Supabase database by `python sidnl.py export-schema`. Do not edit by hand.
-- Documentation and recovery baseline only: the objects already exist in production; never apply this file there.
-- Recovery on an empty database: apply 01, 02, 03 in order, then run `select silver.run_pipeline(true, 'rebuild')`
-- to rebuild silver from bronze, then `select silver.run_gold_pending()` to rebuild dash.

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION dash.refresh(p_visibility_days integer DEFAULT 3)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'dash', 'silver', 'public', 'pg_temp'
AS $function$
declare
  v_stats jsonb := '{}'::jsonb; n bigint;
  v_top numeric; v_tol numeric; v_crit numeric; v_hi numeric; v_med numeric; v_low numeric; v_ref text;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_vis_from date;
begin
  select coalesce(max(value) filter (where key = 'top_of_search_n'), 10),
         coalesce(max(value) filter (where key = 'parity_tolerance_pct'), 1),
         coalesce(max(value) filter (where key = 'critical_osa_pct'), 50),
         coalesce(max(value) filter (where key = 'priority_high_osa_pct'), 30),
         coalesce(max(value) filter (where key = 'priority_medium_osa_pct'), 60),
         coalesce(max(value) filter (where key = 'low_stock_fe_units'), 5),
         coalesce(max(value_text) filter (where key = 'parity_reference_platform'), 'blinkit')
    into v_top, v_tol, v_crit, v_hi, v_med, v_low, v_ref
    from dash.cfg_threshold;
  v_vis_from := case when p_visibility_days is null then '-infinity'::date else v_today - p_visibility_days end;

  -- PRICING
  delete from dash.pricing;
  drop table if exists _dash_pr;
  create temp table _dash_pr on commit drop as
    select distinct on (v.product_key, v.store_key, v.obs_date)
           v.obs_date, v.platform, coalesce(v.city_slug, '(unknown)') as city_slug, v.store_key, x.sidnl_id,
           v.mrp, v.selling_price, d.total_content, d.size_unit, c.threshold_sp
    from dash.v_valid_reading v
    join silver.product_xref x on x.product_key = v.product_key
    join silver.dim_product d  on d.product_key = v.product_key
    left join dash.cfg_sku c   on c.platform = d.platform and c.platform_product_id = d.platform_product_id
    where v.store_key is not null and v.selling_price is not null and v.mrp > 0
    order by v.product_key, v.store_key, v.obs_date, v.observed_at desc, v.reading_key desc;

  insert into dash.pricing (obs_date, platform, city_slug, sidnl_id, stores_observed, mrp, selling_price,
         min_selling_price, max_selling_price, discount_amount, discount_pct, weighted_discount_pct,
         price_per_100g, threshold_sp)
  select obs_date, platform, city_slug, sidnl_id, count(distinct store_key),
         round(avg(mrp), 2), round(avg(selling_price), 2), min(selling_price), max(selling_price),
         round(avg(mrp - selling_price), 2),
         round(avg(100.0 * (mrp - selling_price) / mrp), 2),
         round(100.0 * sum(mrp - selling_price) / nullif(sum(mrp), 0), 2),
         round(avg(case when size_unit in ('g', 'ml') and total_content > 0 then 100.0 * selling_price / total_content end), 2),
         min(threshold_sp)
  from _dash_pr
  group by obs_date, platform, city_slug, sidnl_id;
  get diagnostics n = row_count; v_stats := v_stats || jsonb_build_object('pricing', n);

  update dash.pricing p set
         price_vs_national_pct = case when q.national_sp > 0 then round(100.0 * (p.selling_price - q.national_sp) / q.national_sp, 2) end,
         price_gap_vs_lowest_marketplace_pct =
           case when q.platforms > 1 and q.lowest_sp > 0 then round(100.0 * (p.selling_price - q.lowest_sp) / q.lowest_sp, 2) end,
         price_gap_vs_reference_pct =
           case when q.reference_sp > 0 and q.platforms > 1 then round(100.0 * (p.selling_price - q.reference_sp) / q.reference_sp, 2) end,
         is_parity_break =
           case when q.reference_sp > 0 and q.platforms > 1 then abs(100.0 * (p.selling_price - q.reference_sp) / q.reference_sp) > v_tol end,
         threshold_diff = case when p.threshold_sp is not null then p.selling_price - p.threshold_sp end,
         sp_change_pct = case when q.prev_sp > 0 then round(100.0 * (p.selling_price - q.prev_sp) / q.prev_sp, 2) end,
         discount_change_pts = p.discount_pct - q.prev_disc
  from (
    select t.obs_date, t.platform, t.city_slug, t.sidnl_id,
           n.national_sp,
           min(t.selling_price) over m as lowest_sp,
           count(*) over m as platforms,
           max(t.selling_price) filter (where t.platform = v_ref) over m as reference_sp,
           lag(t.selling_price) over h as prev_sp,
           lag(t.discount_pct) over h as prev_disc
    from dash.pricing t
    join (select obs_date, platform, sidnl_id, avg(selling_price) national_sp from _dash_pr group by 1, 2, 3) n
      on n.obs_date = t.obs_date and n.platform = t.platform and n.sidnl_id = t.sidnl_id
    window m as (partition by t.obs_date, t.city_slug, t.sidnl_id),
           h as (partition by t.platform, t.city_slug, t.sidnl_id order by t.obs_date)
  ) q
  where q.obs_date = p.obs_date and q.platform = p.platform and q.city_slug = p.city_slug and q.sidnl_id = p.sidnl_id;

  -- AVAILABILITY
  delete from dash.availability;
  drop table if exists _dash_av;
  create temp table _dash_av on commit drop as
  with rd as (
    select v.obs_date, v.platform, coalesce(v.city_slug, '(unknown)') as city_slug, v.store_key, x.sidnl_id,
           v.observed_at, v.reading_key, v.is_listed, v.is_available, v.osa_eligible,
           v.stock_status, v.inventory_units, v.inventory_is_capped
    from dash.v_valid_reading v
    join silver.product_xref x on x.product_key = v.product_key
    where v.store_key is not null
  ), scan as (
    select distinct on (s.brand_key, s.store_key, (s.scanned_at at time zone 'Asia/Kolkata')::date)
           (s.scanned_at at time zone 'Asia/Kolkata')::date as obs_date, s.platform, s.brand_key, s.store_key,
           coalesce(s.city_slug, '(unknown)') as city_slug, s.snapshot_id
    from silver.fact_store_scan s
    join silver.dim_platform pl on pl.platform = s.platform and not pl.is_test
    where s.is_valid_denominator and s.store_key is not null
    order by s.brand_key, s.store_key, (s.scanned_at at time zone 'Asia/Kolkata')::date, s.scanned_at desc, s.snapshot_id desc
  ), lst as (
    select distinct f.snapshot_id, x.sidnl_id
    from silver.fact_product_reading f
    join silver.product_xref x on x.product_key = f.product_key
    where f.source_type = 'brand_search' and f.dq_status = 'valid' and f.is_listed
  ), ds as (
    select sc.obs_date, sc.platform, sc.city_slug, sc.store_key, x.sidnl_id,
           1 as dse, max(case when l.sidnl_id is not null then 1 else 0 end) as dsl
    from scan sc
    join silver.dim_product d  on d.platform = sc.platform and d.brand_key = sc.brand_key
    join silver.product_xref x on x.product_key = d.product_key
    left join lst l on l.snapshot_id = sc.snapshot_id and l.sidnl_id = x.sidnl_id
    group by 1, 2, 3, 4, 5
  ), osa as (
    select obs_date, platform, city_slug, store_key, sidnl_id,
           count(*) as oe, count(*) filter (where is_available) as oa,
           count(*) filter (where is_listed) as ole, count(*) filter (where is_listed and is_available) as ola
    from rd where osa_eligible and is_available is not null
    group by 1, 2, 3, 4, 5
  ), lat as (
    select distinct on (obs_date, store_key, sidnl_id)
           obs_date, platform, city_slug, store_key, sidnl_id, observed_at, inventory_units, inventory_is_capped,
           case when is_available is not null then is_available
                when stock_status = 'in_stock' then true
                when stock_status = 'out_of_stock' then false end as avail
    from rd
    order by obs_date, store_key, sidnl_id, observed_at desc, reading_key desc
  ), k as (
    select obs_date, platform, city_slug, store_key, sidnl_id from ds
    union select obs_date, platform, city_slug, store_key, sidnl_id from osa
    union select obs_date, platform, city_slug, store_key, sidnl_id from lat
  )
  select k.obs_date, k.platform, k.city_slug, k.store_key, k.sidnl_id,
         coalesce(ds.dse, 0) as dse, coalesce(ds.dsl, 0) as dsl,
         coalesce(o.oe, 0) as oe, coalesce(o.oa, 0) as oa, coalesce(o.ole, 0) as ole, coalesce(o.ola, 0) as ola,
         case when l.avail then 1 else 0 end as ins,
         case when l.avail = false then 1 else 0 end as oos,
         case when l.avail and l.inventory_units <= v_low then 1 else 0 end as low,
         l.inventory_units as inv,
         case when l.inventory_is_capped then 1 else 0 end as cap,
         l.observed_at
  from k
  left join ds    using (obs_date, platform, city_slug, store_key, sidnl_id)
  left join osa o using (obs_date, platform, city_slug, store_key, sidnl_id)
  left join lat l using (obs_date, platform, city_slug, store_key, sidnl_id);

  insert into dash.availability (obs_date, platform, city_slug, sidnl_id, store_key,
         ds_eligible_stores, ds_listed_stores, ds_listing_pct,
         osa_eligible_obs, osa_available_obs, osa_pct, osa_in_ls_eligible_obs, osa_in_ls_available_obs, osa_in_ls_pct,
         in_stock_stores, out_of_stock_stores, low_stock_stores, inventory_fe, inventory_fe_capped_stores, last_observed_at)
  select obs_date, platform, city_slug, sidnl_id, store_key,
         dse, dsl, case when dse > 0 then round(100.0 * dsl / dse, 2) end,
         oe, oa, case when oe > 0 then round(100.0 * oa / oe, 2) end,
         ole, ola, case when ole > 0 then round(100.0 * ola / ole, 2) end,
         ins, oos, low, inv, cap, observed_at
  from _dash_av;
  get diagnostics n = row_count; v_stats := v_stats || jsonb_build_object('availability_store_rows', n);

  insert into dash.availability (obs_date, platform, city_slug, sidnl_id, store_key,
         ds_eligible_stores, ds_listed_stores, ds_listing_pct,
         osa_eligible_obs, osa_available_obs, osa_pct, osa_in_ls_eligible_obs, osa_in_ls_available_obs, osa_in_ls_pct,
         in_stock_stores, out_of_stock_stores, low_stock_stores, inventory_fe, inventory_fe_capped_stores, last_observed_at,
         is_critical, priority)
  select obs_date, platform, city_slug, sidnl_id, null,
         sum(dse), sum(dsl), case when sum(dse) > 0 then round(100.0 * sum(dsl) / sum(dse), 2) end,
         sum(oe), sum(oa), case when sum(oe) > 0 then round(100.0 * sum(oa) / sum(oe), 2) end,
         sum(ole), sum(ola), case when sum(ole) > 0 then round(100.0 * sum(ola) / sum(ole), 2) end,
         sum(ins), sum(oos), sum(low), sum(inv), sum(cap), max(observed_at),
         case when sum(oe) > 0 then 100.0 * sum(oa) / sum(oe) < v_crit end,
         case when sum(oe) = 0 then null
              when 100.0 * sum(oa) / sum(oe) < v_hi then 'High'
              when 100.0 * sum(oa) / sum(oe) < v_med then 'Medium' else 'Low' end
  from _dash_av
  group by obs_date, platform, city_slug, sidnl_id;
  get diagnostics n = row_count; v_stats := v_stats || jsonb_build_object('availability_city_rows', n);

  update dash.availability a set
         potential_sales_loss = q.psl,
         drr = q.drr,
         doi_fe = case when q.drr > 0 and a.inventory_fe is not null then round(a.inventory_fe / q.drr, 1) end
  from (
    select c.obs_date, c.platform, c.city_slug, c.sidnl_id,
           round(c.out_of_stock_stores * coalesce(p.selling_price, nat.sp), 2) as psl,
           s.drr
    from dash.availability c
    left join dash.pricing p on p.obs_date = c.obs_date and p.platform = c.platform
                            and p.city_slug = c.city_slug and p.sidnl_id = c.sidnl_id
    left join (select platform, sidnl_id, avg(selling_price) as sp from dash.pricing group by 1, 2) nat
           on nat.platform = c.platform and nat.sidnl_id = c.sidnl_id
    left join lateral (select round(sum(o.units_sold)::numeric / 30, 2) as drr from dash.overview o
                       where o.platform = c.platform and o.city_slug = c.city_slug and o.sidnl_id = c.sidnl_id
                         and o.obs_date > c.obs_date - 30 and o.obs_date <= c.obs_date
                       having count(*) > 0) s on true
    where c.store_key is null
  ) q
  where a.store_key is null
    and a.obs_date = q.obs_date and a.platform = q.platform and a.city_slug = q.city_slug and a.sidnl_id = q.sidnl_id;

  -- VISIBILITY
  delete from dash.visibility where obs_date >= v_vis_from;

  insert into dash.visibility (obs_date, platform, city_slug, search_type, search_term, sidnl_id,
         stores_scanned, stores_listed, listing_coverage_pct,
         impressions, organic_impressions, paid_impressions,
         top_of_search_impressions, top_of_search_organic_impressions, top_of_search_paid_impressions,
         best_search_rank, avg_search_rank, avg_organic_rank,
         share_of_voice_pct, organic_sov_pct, paid_sov_pct,
         top_of_search_sov_pct, top_of_search_organic_sov_pct, top_of_search_paid_sov_pct)
  with snap as (
    select distinct on (platform, l1_id, l2_id, store_key, obs_date) snapshot_id
    from silver.fact_shelf_position
    where store_key is not null and obs_date >= v_vis_from
    order by platform, l1_id, l2_id, store_key, obs_date, observed_at desc, snapshot_id desc
  ), r as (
    select f.obs_date, f.platform, coalesce(f.city_slug, '(unknown)') as c, f.l1_id || '>' || f.l2_id as term,
           f.store_key, x.sidnl_id, f.brand_key, f.shelf_position, f.organic_position, coalesce(f.is_ad, false) as ad
    from silver.fact_shelf_position f
    join snap s on s.snapshot_id = f.snapshot_id
    join silver.product_xref x on x.product_key = f.product_key
    join silver.dim_platform pl on pl.platform = f.platform and not pl.is_test
    where f.dq_status = 'valid' and f.store_key is not null and f.obs_date >= v_vis_from
  ), mk as (
    select obs_date, platform, c, term,
           count(distinct store_key) as stores, count(distinct brand_key) as brands,
           count(*) as imp, count(*) filter (where not ad) as org, count(*) filter (where ad) as paid,
           count(*) filter (where shelf_position <= v_top) as top,
           count(*) filter (where shelf_position <= v_top and not ad) as top_org,
           count(*) filter (where shelf_position <= v_top and ad) as top_paid
    from r group by 1, 2, 3, 4
  ), sk as (
    select obs_date, platform, c, term, sidnl_id,
           count(distinct store_key) as stores,
           count(*) as imp, count(*) filter (where not ad) as org, count(*) filter (where ad) as paid,
           count(*) filter (where shelf_position <= v_top) as top,
           count(*) filter (where shelf_position <= v_top and not ad) as top_org,
           count(*) filter (where shelf_position <= v_top and ad) as top_paid,
           min(shelf_position) as best, round(avg(shelf_position), 2) as avg_rank, round(avg(organic_position), 2) as avg_org
    from r group by 1, 2, 3, 4, 5
  )
  select s.obs_date, s.platform, s.c, 'category', s.term, s.sidnl_id,
         m.stores, s.stores, round(100.0 * s.stores / nullif(m.stores, 0), 2),
         s.imp, s.org, s.paid, s.top, s.top_org, s.top_paid,
         s.best, s.avg_rank, s.avg_org,
         case when m.brands >= 2 and m.imp > 0      then round(100.0 * s.imp / m.imp, 3) end,
         case when m.brands >= 2 and m.org > 0      then round(100.0 * s.org / m.org, 3) end,
         case when m.brands >= 2 and m.paid > 0     then round(100.0 * s.paid / m.paid, 3) end,
         case when m.brands >= 2 and m.top > 0      then round(100.0 * s.top / m.top, 3) end,
         case when m.brands >= 2 and m.top_org > 0  then round(100.0 * s.top_org / m.top_org, 3) end,
         case when m.brands >= 2 and m.top_paid > 0 then round(100.0 * s.top_paid / m.top_paid, 3) end
  from sk s join mk m using (obs_date, platform, c, term);
  get diagnostics n = row_count; v_stats := v_stats || jsonb_build_object('visibility_category', n);

  insert into dash.visibility (obs_date, platform, city_slug, search_type, search_term, sidnl_id,
         stores_scanned, stores_listed, listing_coverage_pct,
         impressions, organic_impressions, paid_impressions,
         top_of_search_impressions, top_of_search_organic_impressions, top_of_search_paid_impressions,
         best_search_rank, avg_search_rank, avg_organic_rank)
  with sc as (
    select distinct on (s.store_key, lower(btrim(s.scrape_query)), (s.scanned_at at time zone 'Asia/Kolkata')::date)
           s.snapshot_id, (s.scanned_at at time zone 'Asia/Kolkata')::date as obs_date, s.platform,
           coalesce(s.city_slug, '(unknown)') as c, s.store_key, lower(btrim(s.scrape_query)) as term
    from silver.fact_store_scan s
    join silver.dim_platform pl on pl.platform = s.platform and not pl.is_test
    where s.is_valid_denominator and s.store_key is not null and nullif(btrim(s.scrape_query), '') is not null
      and (s.scanned_at at time zone 'Asia/Kolkata')::date >= v_vis_from
    order by s.store_key, lower(btrim(s.scrape_query)), (s.scanned_at at time zone 'Asia/Kolkata')::date, s.scanned_at desc, s.snapshot_id desc
  ), mk as (
    select obs_date, platform, c, term, count(distinct store_key) as stores from sc group by 1, 2, 3, 4
  ), r as (
    select sc.obs_date, sc.platform, sc.c, sc.term, sc.store_key, x.sidnl_id,
           f.search_position, f.organic_position, coalesce(f.is_ad, false) as ad
    from sc
    join silver.fact_product_reading f on f.snapshot_id = sc.snapshot_id and f.source_type = 'brand_search'
         and f.dq_status = 'valid' and f.is_listed and f.search_position is not null
    join silver.product_xref x on x.product_key = f.product_key
  )
  select r.obs_date, r.platform, r.c, 'keyword', r.term, r.sidnl_id,
         m.stores, count(distinct r.store_key), round(100.0 * count(distinct r.store_key) / nullif(m.stores, 0), 2),
         count(*), count(*) filter (where not r.ad), count(*) filter (where r.ad),
         count(*) filter (where r.search_position <= v_top),
         count(*) filter (where r.search_position <= v_top and not r.ad),
         count(*) filter (where r.search_position <= v_top and r.ad),
         min(r.search_position), round(avg(r.search_position), 2), round(avg(r.organic_position), 2)
  from r join mk m using (obs_date, platform, c, term)
  group by r.obs_date, r.platform, r.c, r.term, r.sidnl_id, m.stores;
  get diagnostics n = row_count; v_stats := v_stats || jsonb_build_object('visibility_keyword', n);

  return v_stats || jsonb_build_object('visibility_from', v_vis_from, 'refreshed_at', now());
end
$function$
;

CREATE OR REPLACE FUNCTION dash.sync_dims()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'public', 'pg_temp'
AS $function$
begin
    insert into dash.dim_platform select platform from silver.dim_platform where not is_test on conflict do nothing;

    insert into dash.dim_city (city_slug, city_name, state)
        select city_slug, city_name, state from silver.dim_city
        on conflict (city_slug) do update set city_name = excluded.city_name, state = excluded.state
        where (dash.dim_city.city_name, dash.dim_city.state) is distinct from (excluded.city_name, excluded.state);
    insert into dash.dim_city values ('ALL', 'All cities', null), ('(unknown)', 'Unknown city', null) on conflict do nothing;

    insert into dash.dim_brand (brand_key, brand_name, company_name)
        select brand_key, brand_name, company_name from silver.dim_brand
        on conflict (brand_key) do update set brand_name = excluded.brand_name, company_name = excluded.company_name
        where (dash.dim_brand.brand_name, dash.dim_brand.company_name) is distinct from (excluded.brand_name, excluded.company_name);

    insert into dash.dim_category (platform, l1_id, l2_id, l1_name, l2_name)
        select platform, l1_id, l2_id, l1_name, l2_name from silver.category_scope
        on conflict (platform, l1_id, l2_id) do update set l1_name = excluded.l1_name, l2_name = excluded.l2_name
        where (dash.dim_category.l1_name, dash.dim_category.l2_name) is distinct from (excluded.l1_name, excluded.l2_name);

    insert into dash.dim_product (product_key, platform, platform_product_id, brand_key, product_name, variant, pack_raw, catalog_product_id, category_path, sidnl_id)
        select p.product_key, p.platform, p.platform_product_id, p.brand_key, p.product_name, p.variant, p.pack_raw, p.catalog_product_id, c.category_path, x.sidnl_id
        from silver.dim_product p
        left join silver.dim_category c on c.category_key = p.category_key
        left join silver.product_xref x on x.product_key = p.product_key
        where p.platform in (select platform from dash.dim_platform)
        on conflict (product_key) do update set product_name = excluded.product_name, variant = excluded.variant,
            pack_raw = excluded.pack_raw, catalog_product_id = excluded.catalog_product_id, category_path = excluded.category_path,
            sidnl_id = excluded.sidnl_id
        where (dash.dim_product.product_name, dash.dim_product.variant, dash.dim_product.pack_raw, dash.dim_product.catalog_product_id, dash.dim_product.category_path, dash.dim_product.sidnl_id)
              is distinct from (excluded.product_name, excluded.variant, excluded.pack_raw, excluded.catalog_product_id, excluded.category_path, excluded.sidnl_id);

    insert into dash.dim_store (store_key, platform, store_name, city_slug)
        select store_key, platform, store_name, city_slug from silver.dim_store
        where platform in (select platform from dash.dim_platform)
        on conflict (store_key) do update set store_name = excluded.store_name, city_slug = excluded.city_slug
        where (dash.dim_store.store_name, dash.dim_store.city_slug) is distinct from (excluded.store_name, excluded.city_slug);

    delete from dash.dim_sidnl;
    insert into dash.dim_sidnl
    select cp.sidnl_id, cp.brand_key, cp.canonical_name, cp.variant, cp.size_value, cp.size_unit, cp.pack_count,
           coalesce(nullif(concat_ws(' > ', cp.category_l1, cp.category_l2, cp.category_l3), ''),
                    (select max(gp.category_path) from dash.dim_product gp where gp.sidnl_id = cp.sidnl_id))
    from silver.canonical_product cp
    where exists (select 1 from dash.dim_product k where k.sidnl_id = cp.sidnl_id);

    update dash.dim_brand b
       set is_client = exists (select 1 from silver.brand_scope s where s.brand_key = b.brand_key and s.is_enabled)
     where b.is_client is distinct from exists (select 1 from silver.brand_scope s where s.brand_key = b.brand_key and s.is_enabled);
end $function$
;

CREATE OR REPLACE FUNCTION ops.alert_claim(p_limit integer DEFAULT 10)
 RETURNS TABLE(alert_id bigint, source text, severity text, title text, body text, attempts integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ops', 'silver', 'public', 'pg_temp'
AS $function$ begin
    if coalesce(silver.cfg('alert_delivery_enabled'), 0) <> 1 then return; end if;
    update ops.alert_outbox set status = 'failed', last_error = 'reclaimed: stuck in sending past claim timeout'
     where status = 'sending' and claimed_at < now() - make_interval(mins => coalesce(silver.cfg('alert_claim_timeout_minutes'), 5)::int);
    return query
    update ops.alert_outbox o set status = 'sending', claimed_at = now(), attempts = o.attempts + 1
     where o.alert_id in (select a.alert_id from ops.alert_outbox a where a.status = 'pending' and a.next_attempt_at <= now()
                           order by a.alert_id for update skip locked limit p_limit)
     returning o.alert_id, o.source, o.severity, o.title, o.body, o.attempts;
end $function$
;

CREATE OR REPLACE FUNCTION ops.alert_mark(p_alert_id bigint, p_ok boolean, p_err text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ops', 'silver', 'public', 'pg_temp'
AS $function$ begin
    if p_ok then update ops.alert_outbox set status = 'sent', sent_at = now(), last_error = null where alert_id = p_alert_id;
    else update ops.alert_outbox o set status = case when o.attempts >= coalesce(silver.cfg('alert_max_attempts'), 6)::int then 'dead' else 'pending' end,
                next_attempt_at = now() + make_interval(mins => silver.backoff_minutes(o.attempts)), last_error = p_err
          where o.alert_id = p_alert_id; end if;
end $function$
;

CREATE OR REPLACE FUNCTION ops.cron_alert_to_outbox()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ops', 'silver', 'public', 'pg_temp'
AS $function$ begin
    insert into ops.alert_outbox (dedupe_key, source, severity, title, body)
    values ('cron:' || new.alert_id::text, 'cron', case when new.level = 'alert' then 'warning' else 'info' end,
            new.jobname || ': ' || new.level,
            coalesce(new.consecutive_failures::text || ' consecutive failure(s). Last: ' || left(new.last_failure_message, 400), new.level))
    on conflict (dedupe_key) do nothing;
    return new;
exception when others then raise warning 'cron_alert_to_outbox: %', sqlerrm; return new; end $function$
;

CREATE OR REPLACE FUNCTION ops.heartbeat()
 RETURNS SETOF ops.v_heartbeat
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'ops', 'silver', 'public', 'pg_temp'
AS $function$ select * from ops.v_heartbeat $function$
;

CREATE OR REPLACE FUNCTION ops.storage_alert_to_outbox()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ops', 'silver', 'public', 'pg_temp'
AS $function$ begin
    insert into ops.alert_outbox (dedupe_key, source, severity, title, body)
    values ('storage:' || new.alert_id::text, 'storage',
            case when new.level = 'critical' then 'critical' when new.level = 'warning' then 'warning' else 'info' end,
            'storage ' || new.level, coalesce(new.message || ' (' || new.used_pct::text || '%)', 'storage level: ' || new.level))
    on conflict (dedupe_key) do nothing;
    return new;
exception when others then raise warning 'storage_alert_to_outbox: %', sqlerrm; return new; end $function$
;

CREATE OR REPLACE FUNCTION public.sidnl_heartbeat(p_token text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ops', 'silver', 'public', 'pg_temp'
AS $function$
declare v_tok text; v_given text; v_jobs json; v_bad int; v_alert_late int := 0;
begin
    select decrypted_secret into v_tok from vault.decrypted_secrets where name = 'heartbeat_token' order by created_at desc limit 1;
    v_given := coalesce(p_token, nullif(current_setting('request.headers', true), '')::json ->> 'x-heartbeat-token');
    if v_tok is null or v_given is distinct from v_tok then
        perform set_config('response.status', '401', true);
        return json_build_object('ok', false, 'error', 'unauthorized');
    end if;
    select json_agg(json_build_object('job', jobname, 'active', active, 'last_start', last_start, 'last_status', last_status, 'overdue', od) order by jobname),
           count(*) filter (where od)
      into v_jobs, v_bad
      from (select h.*, (not h.active
                         or (h.last_start is null and h.schedule !~ '^\d+ \d+ \* \* \*$')
                         or h.last_status = 'failed'
                         or (h.last_start is not null and h.last_start < h.expected_by)) as od
              from ops.v_heartbeat h) z;
    if coalesce(silver.cfg('alert_delivery_enabled'), 0) = 1 then
        select count(*) into v_alert_late from ops.alert_outbox where status = 'pending' and created_at < now() - interval '30 minutes';
    end if;
    if v_bad > 0 or v_alert_late > 0 then perform set_config('response.status', '503', true); end if;
    return json_build_object('ok', v_bad = 0 and v_alert_late = 0, 'checked_at', now(), 'jobs_overdue', v_bad,
                             'alerts_pending_over_30min', v_alert_late, 'jobs', v_jobs);
end $function$
;

CREATE OR REPLACE FUNCTION silver.approve_match(p_review_id bigint, p_by text DEFAULT SESSION_USER)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
AS $function$
declare q silver.match_review_queue%rowtype; v_from text;
begin
    select * into q from silver.match_review_queue where review_id = p_review_id and status = 'pending' for update;
    if not found then raise exception 'review % not found or already decided', p_review_id; end if;
    select sidnl_id into v_from from silver.product_xref where product_key = q.product_key;
    if v_from = q.suggested_sidnl_id then
        update silver.match_review_queue set status = 'approved', decided_by = p_by, decided_at = now() where review_id = p_review_id;
        return v_from;
    end if;
    return silver.merge_canonical(v_from, q.suggested_sidnl_id, p_by);
end $function$
;

CREATE OR REPLACE FUNCTION silver.auto_approve_exact_matches()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
AS $function$
declare
    r record; v_ok bigint[] := '{}'; v_skip jsonb := '[]'::jsonb;
begin
    if coalesce(silver.cfg('auto_match_exact_enabled'), 0) <> 1 then
        return jsonb_build_object('status', 'disabled');
    end if;
    if not pg_try_advisory_xact_lock(727100) then
        return jsonb_build_object('status', 'skipped', 'reason', 'pipeline run in progress');
    end if;

    for r in
        select q.review_id
          from silver.match_review_queue q
          join silver.product_xref x  on x.product_key = q.product_key
          join silver.dim_product d   on d.product_key = q.product_key
         where q.status = 'pending'
           and d.brand_key is not null and d.size_value is not null and d.size_unit is not null and d.pack_count is not null
           and x.sidnl_id <> q.suggested_sidnl_id
           and (select count(*) from silver.product_xref x1 where x1.sidnl_id = x.sidnl_id) = 1
           and exists (select 1 from silver.product_xref x2 where x2.sidnl_id = q.suggested_sidnl_id)
           and not exists (select 1 from silver.product_xref x2 join silver.dim_product d2 using (product_key)
                            where x2.sidnl_id = q.suggested_sidnl_id and d2.platform = d.platform)
           and not exists (select 1 from silver.product_xref x2 join silver.dim_product d2 using (product_key)
                            where x2.sidnl_id = q.suggested_sidnl_id
                              and not (d2.brand_key = d.brand_key
                                       and regexp_replace(lower(btrim(d2.product_name)), '\s+', ' ', 'g')
                                         = regexp_replace(lower(btrim(d.product_name)), '\s+', ' ', 'g')
                                       and (d2.size_value, d2.size_unit, d2.pack_count) = (d.size_value, d.size_unit, d.pack_count)))
         order by q.review_id
    loop
        begin
            perform silver.approve_match(r.review_id, 'auto:exact_name_size');
            v_ok := v_ok || r.review_id;
        exception when others then
            v_skip := v_skip || jsonb_build_object('review_id', r.review_id, 'error', sqlerrm);
        end;
    end loop;

    if cardinality(v_ok) > 0 then
        update ops.pipeline_run set gold_status = 'pending'
         where run_id = (select max(run_id) from ops.pipeline_run where status = 'success') and gold_status is distinct from 'pending';
    end if;
    return jsonb_build_object('status', 'ok', 'approved', cardinality(v_ok), 'review_ids', to_jsonb(v_ok), 'skipped', v_skip);
end $function$
;

CREATE OR REPLACE FUNCTION silver.backoff_minutes(p_attempt integer)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select case p_attempt when 1 then 2 when 2 then 4 when 3 then 8 else 16 end
$function$
;

CREATE OR REPLACE FUNCTION silver.brand_matches(p_brand_key text, p_raw text)
 RETURNS boolean
 LANGUAGE sql
 STABLE PARALLEL SAFE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
    select p_raw is not null
       and exists (
            select 1
            from silver.brand_scope b
            where b.brand_key = p_brand_key
              and replace(silver.norm_key(p_raw), ' ', '') = any (
                    select replace(silver.norm_key(a), ' ', '')
                    from unnest(array[b.brand_key, b.brand_name] || b.raw_brand_aliases) a))
$function$
;

CREATE OR REPLACE FUNCTION silver.canon_feat(c silver.canonical_product)
 RETURNS silver.match_feat
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
    select row(c.name_clean, c.brand_key, c.size_value, c.size_unit, c.pack_count,
               c.variant_key, c.category_l1, c.category_l2, c.category_l3)::silver.match_feat
$function$
;

CREATE OR REPLACE FUNCTION silver.canon_tokens(p_text text)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
AS $function$
declare t text := silver.norm_key(p_text); r record;
begin
    if t is null then return '{}'::text[]; end if;
    for r in select syn_key, variant from silver.ref_variant_synonym
              where is_active and syn_key <> variant
              order by length(syn_key) desc, syn_key loop
        t := regexp_replace(t, '(^|\s)' || silver.re_escape(r.syn_key) || '(?=\s|$)', '\1' || r.variant, 'g');
    end loop;
    return array(select distinct x from unnest(string_to_array(t, ' ')) x where x <> '' order by x);
end $function$
;

CREATE OR REPLACE FUNCTION silver.cfg(p_key text)
 RETURNS numeric
 LANGUAGE sql
 STABLE PARALLEL SAFE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
    select value_num from silver.sidnl_config where key = p_key
$function$
;

CREATE OR REPLACE FUNCTION silver.check_cron_alert()
 RETURNS text[]
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare r record; v_thr int := coalesce(silver.cfg('cron_alert_consecutive_failures'), 3)::int;
        v_last text; v_last_at timestamptz; v_out text[] := '{}';
begin
  for r in select * from ops.v_cron_health loop
    select level, alerted_at into v_last, v_last_at from ops.cron_alert_log where jobname = r.jobname order by alert_id desc limit 1;
    if r.consecutive_failures >= v_thr then
      if v_last is distinct from 'alert' or v_last_at < now() - interval '1 day' then
        insert into ops.cron_alert_log(jobname, level, consecutive_failures, last_failure_message)
        values (r.jobname, 'alert', r.consecutive_failures, left(r.last_failure_message, 500));
        raise warning 'SIDNL cron alert: % has % consecutive failures', r.jobname, r.consecutive_failures;
        v_out := v_out || (r.jobname || ':alert');
      end if;
    elsif v_last = 'alert' then
      insert into ops.cron_alert_log(jobname, level, consecutive_failures) values (r.jobname, 'recovered', r.consecutive_failures);
      v_out := v_out || (r.jobname || ':recovered');
    end if;
  end loop;
  return v_out;
end $function$
;

CREATE OR REPLACE FUNCTION silver.check_storage_alert()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare u record; v_last text; v_last_at timestamptz;
begin
  select * into u from silver.storage_usage();
  select level, alerted_at into v_last, v_last_at from ops.storage_alert_log order by alert_id desc limit 1;
  if u.level is distinct from coalesce(v_last,'ok') or (u.level <> 'ok' and v_last_at < now() - interval '1 day') then
    insert into ops.storage_alert_log(level, used_bytes, plan_bytes, used_pct, db_bytes, wal_bytes, message)
    values (u.level, u.used_bytes, u.plan_bytes, u.used_pct, u.db_bytes, u.wal_bytes,
            format('storage %s: %s%% of %s GB plan (db %s MB + wal %s MB)', u.level, u.used_pct, round(u.plan_bytes/1024^3.0,1), u.db_bytes/1048576, u.wal_bytes/1048576));
    if u.level <> 'ok' then raise warning 'SIDNL storage % at % %%', u.level, u.used_pct; end if;
  end if;
  return u.level;
end $function$
;

CREATE OR REPLACE FUNCTION silver.classify_error(p_sqlstate text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select case when left(coalesce(p_sqlstate, ''), 2) in ('22', '23', '42', '0A', '2B', '44', '0L', '28') then 'permanent' else 'transient' end
$function$
;

CREATE OR REPLACE FUNCTION silver.clean_tokens(p_text text, p_brand_key text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
AS $function$
    select coalesce(string_agg(tok, ' ' order by tok), '')
    from unnest(silver.canon_tokens(p_text)) tok
    where length(tok) > 1
      and tok !~ '^[0-9]+$'
      and tok <> all (string_to_array(coalesce(silver.norm_key(p_brand_key), ''), ' '))
      and not exists (select 1 from silver.ref_noise_word n where n.is_active and n.word = tok)
$function$
;

CREATE OR REPLACE FUNCTION silver.deliver_alerts()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare v_url text; r record; v_req bigint; v_ok int := 0; v_retry int := 0; v_sent int := 0;
begin
    if coalesce(silver.cfg('alert_delivery_enabled'), 0) <> 1 then return jsonb_build_object('status', 'disabled'); end if;
    select decrypted_secret into v_url from vault.decrypted_secrets where name = 'slack_webhook_url' order by created_at desc limit 1;
    if v_url is null or v_url !~ '^https://' then return jsonb_build_object('status', 'no webhook secret'); end if;
    -- 1. settle sends made by earlier runs
    for r in select o.alert_id, h.status_code, h.error_msg
               from ops.alert_outbox o join net._http_response h on h.id = o.request_id
              where o.status = 'sending' loop
        if r.status_code between 200 and 299 then
            perform ops.alert_mark(r.alert_id, true); v_ok := v_ok + 1;
        else
            perform ops.alert_mark(r.alert_id, false,
                    left(coalesce('slack responded ' || r.status_code::text, 'no response: ' || r.error_msg, 'no response'), 300));
            v_retry := v_retry + 1;
        end if;
        update ops.alert_outbox set request_id = null where alert_id = r.alert_id;
    end loop;
    -- 2. send due rows (ops.alert_claim also marks rows stuck in 'sending' as failed)
    for r in select * from ops.alert_claim(10) loop
        begin
            v_req := net.http_post(url := v_url, body := jsonb_build_object('text', silver.slack_text(r.severity, r.title, r.body, r.source)),
                                   timeout_milliseconds := 5000);
            update ops.alert_outbox set request_id = v_req where alert_id = r.alert_id;
            v_sent := v_sent + 1;
        exception when others then
            perform ops.alert_mark(r.alert_id, false, left('send failed: ' || replace(sqlerrm, v_url, '[webhook]'), 300));
        end;
    end loop;
    return jsonb_build_object('status', 'ok', 'delivered', v_ok, 'will_retry', v_retry, 'sent_now', v_sent);
end $function$
;

CREATE OR REPLACE FUNCTION silver.dq_checks(p_shelf_max bigint DEFAULT NULL::bigint)
 RETURNS TABLE(check_name text, severity text, scope text, violations bigint, total bigint, ok boolean, blocks boolean, detail text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
with pct as (select coalesce(silver.cfg('dq_reject_block_pct'), 5) as p),
lb  as (select coalesce(greatest(ps.last_seen_id - coalesce(silver.cfg('incremental_lookback_rows'), 5000)::bigint, 0), 0) as lo
          from silver.pipeline_source ps where ps.source_schema = 'public' and ps.source_table = 'shelf_positions'),
t as (
    select f.platform, f.l1_id, f.l2_id, count(*) as total,
           count(*) filter (where 'negative_price' = any (f.dq_flags))                       as neg,
           count(*) filter (where 'sp_gt_mrp'      = any (f.dq_flags))                       as sp,
           count(*) filter (where f.product_key is null and f.platform_product_id is not null) as unlinked,
           count(*) filter (where f.store_key is null)                                       as nostore,
           count(*) filter (where b.brand_key is null)                                       as nobrand
      from silver.fact_shelf_position f
      left join silver.dim_brand b on b.brand_key = f.brand_key
     group by 1, 2, 3),
m as (
    select sn.platform, sn.l1_id, sn.l2_id, count(*) as missing
      from public.shelf_positions sp
      join public.shelf_snapshots sn on sn.id = sp.snapshot_id
      join silver.category_scope cs on cs.platform = sn.platform and cs.l1_id = sn.l1_id
                                   and cs.l2_id = sn.l2_id and cs.is_enabled
      join silver.dim_platform dpl on dpl.platform = sn.platform and not dpl.is_test
      cross join lb
     where sn.status = 'ok' and sp.id > lb.lo
       and sp.id <= coalesce(p_shelf_max, (select max(id) from public.shelf_positions))
       and not exists (select 1 from silver.fact_shelf_position f where f.source_record_id = sp.id)
     group by 1, 2, 3),
per_scope as (
    select c.n, c.sev, t.platform || '/' || t.l1_id || '/' || t.l2_id as scope, c.v, t.total, coalesce(c.blk, false) as blk, c.d
      from t cross join pct
      cross join lateral (values
        ('shelf_negative_selling_price', 'rejected', t.neg,
            t.neg * 100.0 / nullif(t.total, 0) > pct.p,
            'rows rejected from valid analytical output (dq_status=invalid); scope blocked only above dq_reject_block_pct'),
        ('shelf_selling_price_above_mrp', 'warning', t.sp, false,
            'rows flagged suspect and excluded from price/discount metrics; never blocks'),
        ('shelf_row_without_product', 'blocking', t.unlinked, t.unlinked > 0,
            'referential integrity: shelf row has a platform_product_id but no dim_product link'),
        ('shelf_row_without_store', 'blocking', t.nostore, t.nostore > 0,
            'referential integrity: shelf row has no dim_store'),
        ('shelf_row_brand_not_in_dim_brand', 'blocking', t.nobrand, t.nobrand > 0,
            'referential integrity: brand_key missing in dim_brand')
      ) c (n, sev, v, blk, d)
    union all
    select 'shelf_bronze_rows_not_in_silver', 'blocking', m.platform || '/' || m.l1_id || '/' || m.l2_id,
           m.missing, t.total, m.missing > 0,
           'unprocessed bronze rows inside the processing window - watermark must not advance'
      from m left join t on t.platform = m.platform and t.l1_id = m.l1_id and t.l2_id = m.l2_id)
select n, sev, scope, v, total, false, blk, d from per_scope where v > 0
union all
select n, sev, 'all', coalesce(sum(v), 0), coalesce(sum(total), 0), coalesce(sum(v), 0) = 0, coalesce(bool_or(blk), false), min(d)
  from per_scope group by n, sev
union all
select 'dim_store_without_city_or_coords', 'accepted', 'dim_store',
       count(*) filter (where city_slug is null or latitude is null or longitude is null), count(*), true, false,
       'optional descriptive NULLs: kept NULL, not derivable from source'
  from silver.dim_store
union all
select 'dim_product_without_category', 'accepted', 'dim_product',
       count(*) filter (where category_key is null), count(*), true, false,
       'optional descriptive NULLs: kept NULL, not derivable from source'
  from silver.dim_product
union all
select 'canonical_empty_name_clean', 'accepted', 'canonical_product',
       count(*) filter (where coalesce(name_clean, '') = ''), count(*), true, false,
       'approved: unchanged, SI id and raw name preserved'
  from silver.canonical_product where is_active
union all
select 'canonical:' || q.check_name, 'blocking', 'canonical',
       case when q.ok then 0 else 1 end, 1, q.ok, not q.ok, q.detail
  from silver.quality_checks() q
$function$
;

CREATE OR REPLACE FUNCTION silver.dq_run_gate(p_run bigint, p_shelf_max bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare v_out jsonb;
begin
    create temp table _dq on commit drop as select * from silver.dq_checks(p_shelf_max);
    insert into ops.dq_result (run_id, check_name, severity, scope, violations, total, ok, blocks, detail)
    select p_run, check_name, severity, scope, violations, total, ok, blocks, detail from _dq;
    select jsonb_build_object(
        'checks',             count(*) filter (where scope <> 'all'),
        'canonical_blocking', count(*) filter (where blocks and scope = 'canonical'),
        'shelf_blocking',     count(*) filter (where blocks and scope not in ('all', 'canonical')),
        'blocked_scopes',     coalesce(jsonb_agg(distinct check_name || '@' || scope) filter (where blocks and scope <> 'all'), '[]'::jsonb),
        'rejected_rows',      coalesce(sum(violations) filter (where severity = 'rejected' and scope = 'all'), 0),
        'warning_rows',       coalesce(sum(violations) filter (where severity = 'warning'  and scope = 'all'), 0),
        'accepted_nulls',     coalesce(sum(violations) filter (where severity = 'accepted'), 0))
      into v_out from _dq;
    drop table if exists _dq;
    return v_out;
end $function$
;

CREATE OR REPLACE FUNCTION silver.dq_status(p_flags text[])
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
    select case
        when p_flags && array['no_product','no_store','bad_timestamp','unknown_state',
                              'negative_inventory','negative_price'] then 'invalid'
        when p_flags && array['sp_gt_mrp','mrp_missing','oos_with_inventory',
                              'price_missing_in_stock'] then 'suspect'
        else 'valid' end
$function$
;

CREATE OR REPLACE FUNCTION silver.enqueue_daily(p_trigger text DEFAULT 'daily'::text, p_catchup boolean DEFAULT false)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare v_id bigint;
begin
    if p_catchup and (now() at time zone 'Asia/Kolkata')::time < time '00:05' then return null; end if;
    insert into ops.pipeline_job (job_type, job_date, trigger, force, status)
    values ('daily', (now() at time zone 'Asia/Kolkata')::date, coalesce(p_trigger, 'daily'), true, 'queued')
    on conflict do nothing
    returning job_id into v_id;
    return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION silver.enqueue_daily_safe(p_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
 SET lock_timeout TO '5s'
AS $function$ begin return silver.enqueue_daily(p_reason, false);
exception when unique_violation or lock_not_available then return null; end $function$
;

CREATE OR REPLACE FUNCTION silver.enrich_product_categories()
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION silver.exact_key(p_name text, p_pack text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', '', 'g') || '|' ||
           regexp_replace(lower(coalesce(p_pack, '')), '[^a-z0-9+]+', '', 'g')
$function$
;

CREATE OR REPLACE FUNCTION silver.features_from_text(p_name text, p_brand_key text, p_variant text, p_size numeric, p_unit text, p_pack integer, p_l1 text, p_l2 text, p_l3 text)
 RETURNS silver.match_feat
 LANGUAGE sql
 STABLE
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
AS $function$
    select row(
        silver.clean_tokens(
            regexp_replace(lower(coalesce(p_name, '')),
                '\m\d+(?:[.,]\d+)?\s*(?:kgs?|gms?|g|ml|ltrs?|l|pcs?|pieces?|units?|packs?)\M', ' ', 'g'),
            p_brand_key),
        silver.norm_key(p_brand_key),
        p_size, p_unit, coalesce(p_pack, 1),
        silver.clean_tokens(p_variant, p_brand_key),
        silver.norm_key(p_l1), silver.norm_key(p_l2), silver.norm_key(p_l3)
    )::silver.match_feat
$function$
;

CREATE OR REPLACE FUNCTION silver.features_of(p_product_key integer)
 RETURNS silver.match_feat
 LANGUAGE sql
 STABLE
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
AS $function$
    select silver.features_from_text(p.product_name, p.brand_key, p.variant, p.size_value, p.size_unit,
                                     p.pack_count, c.l1_name, c.l2_name, c.l3_name)
    from silver.dim_product p
    left join silver.dim_category c on c.category_key = p.category_key
    where p.product_key = p_product_key
$function$
;

CREATE OR REPLACE FUNCTION silver.fill_store_cities()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare v_st int := 0; v_sh bigint := 0; v_rd bigint := 0;
begin
    if not exists (select 1 from silver.dim_store where city_slug is null)
       and not exists (select 1 from silver.fact_shelf_position f join silver.dim_store ds using (store_key)
                        where f.city_slug is null and ds.city_slug is not null)
       and not exists (select 1 from silver.fact_product_reading f join silver.dim_store ds using (store_key)
                        where f.city_slug is null and ds.city_slug is not null) then
        return jsonb_build_object('status', 'nothing to do');
    end if;
    if not pg_try_advisory_xact_lock(727100) then
        return jsonb_build_object('status', 'skipped', 'reason', 'pipeline run in progress');
    end if;

    -- evidence = the city recorded on every bronze snapshot that produced a fact (or a snapshot) for the store
    with need as (select store_key, source_store_id from silver.dim_store where city_slug is null),
    ev as (
        select z.store_key, min(z.city_slug) as city_slug, count(*) as n
          from (select f.store_key, ss.city_slug
                  from silver.fact_shelf_position f
                  join public.shelf_snapshots ss on ss.id = f.snapshot_id
                 where f.city_slug is null and f.store_key in (select store_key from need) and ss.city_slug is not null
                union all
                select f.store_key, s.city_slug
                  from silver.fact_product_reading f
                  join public.search_snapshots s on s.id = f.snapshot_id
                 where f.source_table = 'public.search_cards' and f.city_slug is null
                   and f.store_key in (select store_key from need) and s.city_slug is not null
                union all
                select f.store_key, ss.city_slug
                  from silver.fact_product_reading f
                  join public.shelf_snapshots ss on ss.id = f.snapshot_id
                 where f.source_table = 'public.shelf_positions' and f.city_slug is null
                   and f.store_key in (select store_key from need) and ss.city_slug is not null
                union all
                select n.store_key, ss.city_slug from need n join public.shelf_snapshots ss on ss.store_id = n.source_store_id
                 where ss.city_slug is not null
                union all
                select n.store_key, s.city_slug from need n join public.search_snapshots s on s.store_id = n.source_store_id
                 where s.city_slug is not null) z
         group by z.store_key
        having count(distinct z.city_slug) = 1),
    upd as (
        update silver.dim_store ds set city_slug = ev.city_slug
          from ev
         where ds.store_key = ev.store_key and ds.city_slug is null
           and exists (select 1 from silver.dim_city c where c.city_slug = ev.city_slug)
        returning ds.store_key, ds.source_store_id, ds.city_slug, ev.n)
    insert into ops.store_city_filled (store_key, source_store_id, city_slug, snapshots)
    select store_key, source_store_id, city_slug, n from upd
    on conflict (store_key) do update set city_slug = excluded.city_slug, snapshots = excluded.snapshots, filled_at = now();
    get diagnostics v_st = row_count;

    update silver.fact_shelf_position f set city_slug = ds.city_slug
      from silver.dim_store ds
     where f.city_slug is null and f.store_key = ds.store_key and ds.city_slug is not null;
    get diagnostics v_sh = row_count;

    update silver.fact_product_reading f set city_slug = ds.city_slug
      from silver.dim_store ds
     where f.city_slug is null and f.store_key = ds.store_key and ds.city_slug is not null;
    get diagnostics v_rd = row_count;

    if v_st + v_sh + v_rd > 0 then
        update ops.pipeline_run set gold_status = 'pending'
         where run_id = (select max(run_id) from ops.pipeline_run where status = 'success') and gold_status is distinct from 'pending';
    end if;
    return jsonb_build_object('status', 'ok', 'stores_filled', v_st, 'shelf_facts_updated', v_sh, 'readings_updated', v_rd);
end $function$
;

CREATE OR REPLACE FUNCTION silver.format_sidnl_id(p_n bigint)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
    select 'SI' || case when p_n < 1000 then lpad(p_n::text, 3, '0') else p_n::text end
$function$
;

CREATE OR REPLACE FUNCTION silver.ignore_dead_letter(p_dl_id bigint, p_by text, p_reason text)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
begin
    if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required'; end if;
    update ops.dead_letter set status = 'ignored', resolved_at = now(), resolved_by = p_by, note = p_reason
     where dl_id = p_dl_id and status = 'open';
    if not found then raise exception 'dead letter % is not open', p_dl_id; end if;
    return 'ignored';
end $function$
;

CREATE OR REPLACE FUNCTION silver.load_category_chunk(p_platform text, p_l1 text, p_l2 text, p_lo bigint, p_hi bigint, p_run bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare v_ins int; v_upd int; v_new_stores int; v_p jsonb;
begin
        with ins as (
            insert into silver.dim_store (platform, store_external_id, source_store_id, store_name, city_slug,
                                          latitude, longitude, first_seen_at, last_seen_at)
            select s.platform, s.external_id, s.id, s.name, s.city_slug, s.lat, s.lon, s.first_seen_at, s.last_seen_at
            from public.stores s
            where s.id in (
                    select distinct coalesce(sp.store_id, sn.store_id)
                    from public.shelf_positions sp
                    join public.shelf_snapshots sn on sn.id = sp.snapshot_id
                    where sp.id > p_lo and sp.id <= p_hi and sn.status = 'ok'
                      and sn.platform = p_platform and sn.l1_id = p_l1 and sn.l2_id = p_l2)
              and s.platform in (select platform from silver.dim_platform)
            on conflict (source_store_id) do nothing
            returning 1)
        select count(*) into v_new_stores from ins;

        with src as materialized (
            select sp.id, sp.snapshot_id, sn.platform, sn.l1_id, sn.l2_id, coalesce(sp.store_id, sn.store_id) as src_store,
                   sn.taken_at, sp."position" as pos, sp.organic_position as opos, sp.is_ad, sp.ad_type, pp.brand,
                   sp.external_id, pp.name, pp.pack, sp.state, sp.inventory, sp.inventory_capped,
                   sp.price::numeric as price, sp.mrp::numeric as mrp,
                   sn.cards_seen, sn.total_items, sn.complete
            from public.shelf_positions sp
            join public.shelf_snapshots sn on sn.id = sp.snapshot_id
            left join public.platform_products pp on pp.platform = sn.platform and pp.external_id = sp.external_id
            join silver.dim_platform dpl on dpl.platform = sn.platform and not dpl.is_test
            where sp.id > p_lo and sp.id <= p_hi and sn.status = 'ok'
              and sn.platform = p_platform and sn.l1_id = p_l1 and sn.l2_id = p_l2
              and not exists (select 1 from ops.dead_letter dl
                               where dl.status = 'open' and dl.source_table = 'public.shelf_positions' and dl.bronze_id = sp.id)
        ), bm as materialized (
            select x.b as raw_brand,
                   (select sb.brand_key from silver.brand_scope sb
                     where sb.is_enabled and silver.brand_matches(sb.brand_key, x.b)
                     order by sb.brand_key limit 1) as client_key
            from (select distinct brand as b from src where brand is not null) x
            offset 0
        ), ins as (
            insert into silver.fact_shelf_position as t (
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
                   s.cards_seen, s.total_items, s.complete, silver.dq_status(q.flags), q.flags, p_run
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
            where (t.snapshot_id, t.store_key, t.city_slug, t.observed_at, t.shelf_position, t.organic_position, t.is_ad, t.ad_type,
                   t.brand_raw, t.brand_key, t.is_client_brand, t.platform_product_id, t.product_name, t.pack_raw, t.stock_status,
                   t.inventory_units, t.inventory_is_capped, t.selling_price, t.mrp, t.shelf_cards_seen, t.shelf_total_items,
                   t.shelf_complete, t.dq_status, t.dq_flags)
                  is distinct from
                  (excluded.snapshot_id, excluded.store_key, excluded.city_slug, excluded.observed_at, excluded.shelf_position,
                   excluded.organic_position, excluded.is_ad, excluded.ad_type, excluded.brand_raw, excluded.brand_key,
                   excluded.is_client_brand, excluded.platform_product_id, excluded.product_name, excluded.pack_raw,
                   excluded.stock_status, excluded.inventory_units, excluded.inventory_is_capped, excluded.selling_price,
                   excluded.mrp, excluded.shelf_cards_seen, excluded.shelf_total_items, excluded.shelf_complete,
                   excluded.dq_status, excluded.dq_flags)
            returning (xmax = 0) as inserted)
        select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;

        v_p := silver.refresh_category_products(p_run, p_lo, p_hi);

        return jsonb_build_object('stores', v_new_stores, 'ins', v_ins, 'upd', v_upd,
                                  'pb', (v_p ->> 'brands')::int, 'pi', (v_p ->> 'ins')::int,
                                  'pu', (v_p ->> 'upd')::int, 'pl', (v_p ->> 'linked')::int, 'dead_lettered', 0);
end $function$
;

CREATE OR REPLACE FUNCTION silver.load_category_range(p_platform text, p_l1 text, p_l2 text, p_lo bigint, p_hi bigint, p_run bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare
    v_state text; v_msg text; v_mid bigint; a jsonb; b jsonb; v_n int;
    v_cap int := coalesce(silver.cfg('dead_letter_max_per_chunk'), 100)::int;
begin
    begin
        return silver.load_category_chunk(p_platform, p_l1, p_l2, p_lo, p_hi, p_run);
    exception when others then
        v_state := sqlstate; v_msg := sqlerrm;
    end;
    if v_state = '22S01' or silver.classify_error(v_state) <> 'permanent' then
        raise exception using errcode = v_state, message = v_msg;
    end if;

    if p_hi - p_lo <= 1 then
        if not exists (select 1 from public.shelf_positions sp join public.shelf_snapshots sn on sn.id = sp.snapshot_id
                        where sp.id = p_hi and sn.status = 'ok'
                          and sn.platform = p_platform and sn.l1_id = p_l1 and sn.l2_id = p_l2) then
            raise exception using errcode = v_state, message = v_msg;   -- not caused by a row of this scope
        end if;
        v_n := coalesce(nullif(current_setting('sidnl.dl_count', true), ''), '0')::int + 1;
        if v_n > v_cap then
            raise exception using errcode = '22S01',
                  message = format('dead-letter cap (%s rows in one chunk) exceeded, error is not row-specific: %s', v_cap, v_msg);
        end if;
        perform set_config('sidnl.dl_count', v_n::text, true);
        insert into ops.dead_letter (source_table, bronze_id, platform, l1_id, l2_id, platform_product_id, reason, sqlstate,
                                     next_retry_at)
        select 'public.shelf_positions', sp.id, sn.platform, sn.l1_id, sn.l2_id, sp.external_id, left(v_msg, 1000), v_state,
               now() + make_interval(mins => coalesce(silver.cfg('dead_letter_retry_minutes'), 60)::int)
          from public.shelf_positions sp join public.shelf_snapshots sn on sn.id = sp.snapshot_id
         where sp.id = p_hi
        on conflict (source_table, bronze_id) do update set
            reason = excluded.reason, sqlstate = excluded.sqlstate, last_seen_at = now(),
            status = case when ops.dead_letter.status in ('resolved', 'retrying') then 'open' else ops.dead_letter.status end;
        return jsonb_build_object('stores', 0, 'ins', 0, 'upd', 0, 'pb', 0, 'pi', 0, 'pu', 0, 'pl', 0, 'dead_lettered', 1);
    end if;

    v_mid := p_lo + (p_hi - p_lo) / 2;
    a := silver.load_category_range(p_platform, p_l1, p_l2, p_lo, v_mid, p_run);
    b := silver.load_category_range(p_platform, p_l1, p_l2, v_mid, p_hi, p_run);
    return jsonb_build_object(
        'stores', coalesce((a->>'stores')::int, 0) + coalesce((b->>'stores')::int, 0),
        'ins',    coalesce((a->>'ins')::int, 0)    + coalesce((b->>'ins')::int, 0),
        'upd',    coalesce((a->>'upd')::int, 0)    + coalesce((b->>'upd')::int, 0),
        'pb',     coalesce((a->>'pb')::int, 0)     + coalesce((b->>'pb')::int, 0),
        'pi',     coalesce((a->>'pi')::int, 0)     + coalesce((b->>'pi')::int, 0),
        'pu',     coalesce((a->>'pu')::int, 0)     + coalesce((b->>'pu')::int, 0),
        'pl',     coalesce((a->>'pl')::int, 0)     + coalesce((b->>'pl')::int, 0),
        'dead_lettered', coalesce((a->>'dead_lettered')::int, 0) + coalesce((b->>'dead_lettered')::int, 0));
end $function$
;

CREATE OR REPLACE FUNCTION silver.map_new_products()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
AS $function$
declare r record; v_counts jsonb := '{}'::jsonb; s text;
begin
    for r in select p.product_key from silver.dim_product p
             where not exists (select 1 from silver.product_xref x where x.product_key = p.product_key)
             order by p.first_seen_at nulls last, p.product_key loop
        perform silver.map_product(r.product_key);
        select match_status into s from silver.product_xref where product_key = r.product_key;
        v_counts := jsonb_set(v_counts, array[s], to_jsonb(coalesce((v_counts ->> s)::int, 0) + 1));
    end loop;
    return v_counts;
end $function$
;

CREATE OR REPLACE FUNCTION silver.map_product(p_product_key integer)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION silver.map_stock_status(p_state text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
    select case lower(btrim(coalesce(p_state, '')))
             when 'in_stock'     then 'in_stock'
             when 'out_of_stock' then 'out_of_stock'
             when 'not_listed'   then 'not_listed'
             else 'unknown' end
$function$
;

CREATE OR REPLACE FUNCTION silver.merge_canonical(p_from text, p_to text, p_by text DEFAULT SESSION_USER)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
AS $function$
declare f text := silver.sidnl_normalize(p_from); t text := silver.sidnl_normalize(p_to);
begin
    if f is null or t is null or f = t then raise exception 'need two different SI ids (got %, %)', p_from, p_to; end if;
    perform 1 from silver.canonical_product where sidnl_id in (f, t) and is_active having count(*) = 2;
    if not found then raise exception 'both SI ids must exist and be active'; end if;
    if exists (select 1 from silver.product_xref x1 join silver.dim_product d1 using (product_key)
               join silver.product_xref x2 on x2.sidnl_id = t
               join silver.dim_product d2 on d2.product_key = x2.product_key
               where x1.sidnl_id = f and d1.platform = d2.platform) then
        raise exception 'cannot merge % into %: both already have a product on the same platform', f, t;
    end if;

    update silver.product_xref set
        sidnl_id = t,
        match_status = case when match_status in ('PENDING_REVIEW','NEW_MASTER') then 'MANUAL' else match_status end,
        match_method = case when match_status in ('PENDING_REVIEW','NEW_MASTER') then 'REVIEW_APPROVED' else match_method end,
        reviewed_by = p_by, reviewed_at = now()
    where sidnl_id = f;

    update silver.canonical_product set is_active = false, merged_into = t where sidnl_id = f;
    update silver.match_review_queue set status = 'approved', decided_by = p_by, decided_at = now()
        where status = 'pending' and suggested_sidnl_id = t
          and product_key in (select product_key from silver.product_xref where sidnl_id = t);
    update silver.match_review_queue set suggested_sidnl_id = t
        where status = 'pending' and suggested_sidnl_id = f
          and not exists (select 1 from silver.match_review_queue q2
                          where q2.product_key = match_review_queue.product_key and q2.suggested_sidnl_id = t);
    delete from silver.match_review_queue where status = 'pending' and suggested_sidnl_id = f;
    return t;
end $function$
;

CREATE OR REPLACE FUNCTION silver.merge_exact_duplicates(p_by text DEFAULT SESSION_USER)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION silver.new_canonical(p_product_key integer, p_method text DEFAULT 'auto'::text)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
AS $function$
declare f silver.match_feat; p silver.dim_product%rowtype; v_id text;
begin
    select * into p from silver.dim_product where product_key = p_product_key;
    f := silver.features_of(p_product_key);
    insert into silver.canonical_product (
        sidnl_id, brand_key, canonical_name, name_clean, variant, variant_key, product_type,
        size_value, size_unit, pack_count, category_l1, category_l2, category_l3,
        anchor_product_key, created_method)
    values (silver.next_sidnl_id(), p.brand_key, p.product_name, f.name_clean, p.variant, nullif(f.variant_key, ''), p.product_type,
            p.size_value, p.size_unit, coalesce(p.pack_count, 1), f.cat_l1, f.cat_l2, f.cat_l3,
            p_product_key, p_method)
    returning sidnl_id into v_id;
    return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION silver.next_sidnl_id()
 RETURNS text
 LANGUAGE sql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
    select silver.format_sidnl_id(nextval('silver.sidnl_id_seq'))
$function$
;

CREATE OR REPLACE FUNCTION silver.norm_key(p_text text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
    select nullif(
        btrim(regexp_replace(
            regexp_replace(
                lower(replace(replace(replace(coalesce(p_text, ''), '&', ' and '), '''', ''), '’', '')),
                '[^a-z0-9]+', ' ', 'g'),
            '\s+', ' ', 'g')),
        '')
$function$
;

CREATE OR REPLACE FUNCTION silver.onboard_brands()
 RETURNS text[]
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION silver.parse_pack(p_pack text)
 RETURNS silver.pack_t
 LANGUAGE plpgsql
 IMMUTABLE PARALLEL SAFE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare
    t text; m text[]; v numeric; u text; cnt int := 1;
    parts text[]; pt text; pm text[]; c int; vv numeric; uu text;
    u0 text; v0 numeric; tot numeric := 0; tcnt int := 0; same boolean := true; ok boolean := true;
begin
    if p_pack is null or btrim(p_pack) = '' then
        return (null::numeric, null::text, 1)::silver.pack_t;
    end if;

    t := lower(btrim(p_pack));
    t := regexp_replace(t, '(\d),(\d{3})\y', '\1\2', 'g');
    t := regexp_replace(t, '(\d),(\d{1,2})\y', '\1.\2', 'g');
    t := regexp_replace(t, '\m(litres?|liters?|ltrs?|ltr)\M', 'l', 'g');
    t := regexp_replace(t, '\m(millilit(?:re|er)s?)\M', 'ml', 'g');
    t := regexp_replace(t, '\m(grams?|gms?|gm)\M', 'g', 'g');
    t := regexp_replace(t, '\m(kgs?|kilograms?)\M', 'kg', 'g');
    -- every word that counts items (not content) becomes "pc"
    t := regexp_replace(t, '(\d)\s*(pcs?|pieces?|units?|nos?|n|u|tabs?|tablets?|capsules?|caps|strips?|sheets?|sachets?|packs?|sets?)\M',
                        '\1 pc', 'g');

    -- "a + b + c": same unit and same size -> size x count; same unit, different sizes -> total; mixed units -> below
    if t ~ '\d\s*(?:kg|g|ml|l|pc)?\s*\+\s*\d' then
        parts := regexp_split_to_array(t, '\s*\+\s*');
        foreach pt in array parts loop
            pm := regexp_match(btrim(pt), '^(?:(\d+)\s*[x×*]\s*)?(\d+(?:\.\d+)?)\s*(kg|g|ml|l|pc)\M');
            if pm is null then ok := false; exit; end if;
            c := coalesce(pm[1]::int, 1); vv := pm[2]::numeric; uu := pm[3];
            if uu = 'kg' then vv := vv * 1000; uu := 'g'; elsif uu = 'l' then vv := vv * 1000; uu := 'ml'; end if;
            if u0 is null then u0 := uu; v0 := vv;
            elsif u0 <> uu then ok := false; exit; end if;
            if vv <> v0 then same := false; end if;
            tot := tot + c * vv; tcnt := tcnt + c;
        end loop;
        if ok and u0 is not null then
            if same then return (v0, u0, tcnt)::silver.pack_t;
            else return (tot, u0, 1)::silver.pack_t; end if;
        end if;
    end if;

    -- count BEFORE the size: "6 x 330 ml", "2 x 10 pc", "40 pc x 25 g", "1 pack (10 x 14 g)"
    m := regexp_match(t, '(\d+)\s*(?:pc\s*)?[x×*]\s*(\d+(?:\.\d+)?)\s*(kg|g|ml|l|pc)\M');
    if m is not null then
        cnt := m[1]::int;  v := m[2]::numeric;  u := m[3];
    else
        -- count AFTER the size at the end of the string: "100 g x 2", "500 ml x 4"
        m := regexp_match(t, '(\d+(?:\.\d+)?)\s*(kg|g|ml|l|pc)\s*[x×*]\s*(\d+)\s*\)?\s*$');
        if m is not null then
            v := m[1]::numeric;  u := m[2];  cnt := m[3]::int;
        else
            m := regexp_match(t, '(\d+(?:\.\d+)?)\s*(kg|g|ml|l)\M');
            if m is not null then
                v := m[1]::numeric;  u := m[2];
                if t !~ '\+' then
                    -- "2 pc (500 g)" keeps its count; a mixed list such as "7 pcs + 102 g" does not multiply
                    m := regexp_match(t, '(\d+)\s*pc\M');
                    if m is not null then cnt := m[1]::int;
                    else
                        m := regexp_match(t, 'pack of\s*(\d+)');
                        if m is not null then cnt := m[1]::int; end if;
                    end if;
                end if;
            else
                -- count only: "10 pcs" = one pack of 10 pieces
                m := regexp_match(t, '(\d+(?:\.\d+)?)\s*pc\M');
                if m is null then m := regexp_match(t, 'pack of\s*(\d+(?:\.\d+)?)'); end if;
                if m is not null then
                    return (m[1]::numeric, 'pc', 1)::silver.pack_t;
                end if;
                return (1::numeric, 'pc', 1)::silver.pack_t;
            end if;
        end if;
    end if;

    if u = 'kg' then v := v * 1000; u := 'g';
    elsif u = 'l' then v := v * 1000; u := 'ml';
    end if;

    return (v, u, greatest(coalesce(cnt, 1), 1))::silver.pack_t;
end $function$
;

CREATE OR REPLACE FUNCTION silver.parse_variant(p_name text, p_brand text, p_ptype text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE PARALLEL SAFE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare v text := coalesce(p_name, '');
begin
    v := regexp_replace(v, '\([^)]*\)', ' ', 'g');
    if p_brand is not null and btrim(p_brand) <> '' then
        v := regexp_replace(v, '^\s*' || silver.re_escape(btrim(p_brand)) || '\s*', ' ', 'i');
    end if;
    if p_ptype is not null and btrim(p_ptype) <> '' then
        v := regexp_replace(v, silver.re_escape(btrim(p_ptype)), ' ', 'i');
    end if;
    v := regexp_replace(v, '\m\d+(?:\.\d+)?\s*(?:kg|gms?|g|ml|ltr|l|pcs?)\M', ' ', 'gi');
    v := btrim(regexp_replace(v, '\s+', ' ', 'g'));
    if v ~ '^[-–—]+$' then return null; end if;
    return nullif(v, '');
end $function$
;

CREATE OR REPLACE FUNCTION silver.pipeline_job_apply(p_job bigint, r jsonb, p_err text, p_state text)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare j ops.pipeline_job%rowtype; v_stage text; v_msg text; v_st text; v_class text; v_attempt int; v_status text;
begin
    select * into j from ops.pipeline_job where job_id = p_job for update;
    v_attempt := j.attempt + 1;
    if p_err is null and r ->> 'status' = 'skipped' then
        if j.requested_at < now() - interval '3 hours' then
            update ops.pipeline_job set status = 'failed', error_class = 'permanent', failed_stage = 'lock',
                   last_error = 'run lock not acquired within 3 hours', finished_at = now(), lock_waits = lock_waits + 1 where job_id = p_job;
            return 'failed';
        end if;
        update ops.pipeline_job set lock_waits = lock_waits + 1, next_attempt_at = now() + interval '50 seconds',
               note = 'waiting for run lock' where job_id = p_job;
        return j.status;
    elsif p_err is null and r ->> 'status' = 'debounced' then
        update ops.pipeline_job set next_attempt_at = now() + interval '110 seconds', note = 'debounced' where job_id = p_job;
        return j.status;
    elsif p_err is null and r ->> 'status' in ('idle', 'idle_blocked') then
        update ops.pipeline_job set status = 'success', finished_at = now(), note = r ->> 'status' where job_id = p_job;
        return 'success';
    elsif p_err is null and r ->> 'status' = 'success' then
        update ops.pipeline_job set status = 'success', attempt = v_attempt, run_id = (r ->> 'run_id')::bigint,
               finished_at = now(), failed_stage = null, last_error = null, next_attempt_at = null, note = null where job_id = p_job;
        return 'success';
    elsif p_err is null and r ->> 'status' = 'blocked' then
        update ops.pipeline_job set status = 'blocked', attempt = v_attempt, run_id = (r ->> 'run_id')::bigint,
               error_class = 'permanent', failed_stage = 'quality_gate', last_error = (r -> 'quality_gate' -> 'blocked_scopes')::text,
               finished_at = now(), next_attempt_at = null, note = 'not retried: data-validation block' where job_id = p_job;
        return 'blocked';
    end if;

    if p_err is not null then
        v_stage := 'run_pipeline'; v_msg := p_err; v_st := p_state;
    else
        select e.key, e.value ->> 'error', e.value ->> 'sqlstate' into v_stage, v_msg, v_st
          from jsonb_each(r -> 'steps') e where e.value ->> 'ok' = 'false' and e.value ? 'error' order by e.key limit 1;
    end if;
    v_class := silver.classify_error(v_st);
    if v_class = 'permanent' or v_attempt >= j.max_attempts then
        v_status := 'failed';
    else
        v_status := 'retry_wait';
    end if;
    update ops.pipeline_job
       set status = v_status, attempt = v_attempt, force = true, run_id = coalesce((r ->> 'run_id')::bigint, run_id),
           failed_stage = v_stage, error_class = v_class, last_error = left(v_msg, 1000), last_sqlstate = v_st,
           next_attempt_at = case when v_status = 'retry_wait' then now() + make_interval(mins => silver.backoff_minutes(v_attempt)) end,
           finished_at = case when v_status = 'failed' then now() end,
           note = case when v_status = 'failed' and v_class = 'permanent' then 'permanent error: not retried'
                       when v_status = 'failed' then 'max attempts reached' else 'retry scheduled' end
     where job_id = p_job;
    return v_status;
end $function$
;

CREATE OR REPLACE FUNCTION silver.quality_checks()
 RETURNS TABLE(check_name text, ok boolean, detail text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_parser text; v_n bigint;
begin
    v_parser := silver.selftest_parser();
    check_name := 'parser_selftest'; ok := v_parser = 'all parser tests passed'; detail := v_parser; return next;

    for check_name, ok, detail in
        select 'matcher_selftest:' || t.test, t.ok, t.detail from silver.selftest_matcher_pure() t loop
        return next;
    end loop;

    select count(*) into v_n from silver.dim_product p
     where not exists (select 1 from silver.product_xref x where x.product_key = p.product_key);
    check_name := 'every_product_has_si_id'; ok := v_n = 0; detail := v_n || ' products without an SI id'; return next;

    select count(*) into v_n from silver.product_xref x join silver.canonical_product c using (sidnl_id) where not c.is_active;
    check_name := 'xref_points_to_active_si_id'; ok := v_n = 0; detail := v_n || ' products mapped to a retired SI id'; return next;

    select count(*) into v_n from (
        select x.sidnl_id, d.platform from silver.product_xref x join silver.dim_product d using (product_key)
        group by 1, 2
        having count(*) > 1 and count(distinct silver.exact_key(d.product_name, d.pack_raw)) > 1) z;
    check_name := 'same_platform_pairs_are_exact_duplicates'; ok := v_n = 0;
    detail := v_n || ' SI ids hold two same-platform products that are not exact duplicates'; return next;

    select count(*) into v_n from silver.canonical_product c
     where c.is_active and not exists (select 1 from silver.product_xref x where x.sidnl_id = c.sidnl_id);
    check_name := 'no_empty_si_ids'; ok := v_n = 0; detail := v_n || ' active SI ids without any product'; return next;
end $function$
;

CREATE OR REPLACE FUNCTION silver.re_escape(p_text text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
    select regexp_replace(coalesce(p_text, ''), '([.\\^$*+?()\[\]{}|-])', '\\\1', 'g')
$function$
;

CREATE OR REPLACE FUNCTION silver.reading_dq(p_has_product boolean, p_has_store boolean, p_observed timestamp with time zone, p_status text, p_inventory integer, p_price numeric, p_mrp numeric)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
    select coalesce(array_remove(array[
        case when not coalesce(p_has_product, false) then 'no_product' end,
        case when not coalesce(p_has_store,   false) then 'no_store' end,
        case when p_observed is null or p_observed < timestamptz '2020-01-01'
                  or p_observed > now() + interval '1 day' then 'bad_timestamp' end,
        case when p_status = 'unknown' then 'unknown_state' end,
        case when p_inventory < 0 then 'negative_inventory' end,
        case when p_price < 0 then 'negative_price' end,
        case when p_price > p_mrp and p_mrp > 0 then 'sp_gt_mrp' end,
        case when p_price is not null and coalesce(p_mrp, 0) <= 0 then 'mrp_missing' end,
        case when p_status = 'out_of_stock' and coalesce(p_inventory, 0) > 0 then 'oos_with_inventory' end,
        case when p_status = 'in_stock' and p_price is null then 'price_missing_in_stock' end,
        case when p_status = 'out_of_stock' and p_price is null then 'info_price_missing_oos' end,
        case when p_status = 'not_listed' then 'info_not_listed' end
    ], null), '{}'::text[])
$function$
;

CREATE OR REPLACE FUNCTION silver.reconcile()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare
    v_win interval := make_interval(days => coalesce(silver.cfg('reconcile_window_days'), 3)::int);
    v_now timestamptz := now(); r record; v_bad bigint := 0; v_gold_ok boolean; j jsonb;
begin
    if not pg_try_advisory_xact_lock(727100) then return jsonb_build_object('status', 'skipped', 'reason', 'pipeline running'); end if;
    if not pg_try_advisory_xact_lock(727101) then return jsonb_build_object('status', 'skipped', 'reason', 'gold running'); end if;

    -- hop 1a: readings vs bronze
    with b as (
        select 'public.observations' as st, o.id, o.price, o.mrp, o.observed_at as ts, o.store_id, st_.city_slug as city, l.platform, l.external_id as ext
          from public.observations o join public.platform_listings l on l.id = o.listing_id left join public.stores st_ on st_.id = o.store_id
         where o.id in (select source_record_id from silver.fact_product_reading where source_table = 'public.observations' and loaded_at > v_now - v_win)
        union all
        select 'public.search_cards', c.id, c.price, c.mrp, s.taken_at, coalesce(c.store_id, s.store_id), st_.city_slug, s.platform, c.external_id
          from public.search_cards c join public.search_snapshots s on s.id = c.snapshot_id left join public.stores st_ on st_.id = coalesce(c.store_id, s.store_id)
         where c.id in (select source_record_id from silver.fact_product_reading where source_table = 'public.search_cards' and loaded_at > v_now - v_win)
        union all
        select 'public.shelf_positions', p.id, p.price, p.mrp, ss.taken_at, p.store_id, st_.city_slug, ss.platform, p.external_id
          from public.shelf_positions p join public.shelf_snapshots ss on ss.id = p.snapshot_id left join public.stores st_ on st_.id = p.store_id
         where p.id in (select source_record_id from silver.fact_product_reading where source_table = 'public.shelf_positions' and loaded_at > v_now - v_win))
    select count(*) as n,
           count(*) filter (where b.id is null or f.selling_price is distinct from b.price or f.mrp is distinct from b.mrp
                              or f.observed_at is distinct from b.ts or ds.source_store_id is distinct from b.store_id
                              or dp.platform is distinct from b.platform::text or dp.platform_product_id is distinct from b.ext::text
                              or f.city_slug is distinct from coalesce(b.city::text, scf.city_slug)) as bad
      into r
      from silver.fact_product_reading f
      left join b on b.st = f.source_table and b.id = f.source_record_id
      left join silver.dim_store ds on ds.store_key = f.store_key
      left join silver.dim_product dp on dp.product_key = f.product_key
      left join ops.store_city_filled scf on scf.store_key = f.store_key
     where f.loaded_at > v_now - v_win;
    insert into ops.reconciliation_log (run_at, check_name, status, rows_checked, mismatches, detail)
    values (v_now, 'readings_vs_bronze', case when r.bad = 0 then 'ok' else 'mismatch' end, r.n, r.bad, jsonb_build_object('window', v_win::text));
    v_bad := v_bad + r.bad;

    -- hop 1b: shelf facts vs bronze
    select count(*) as n,
           count(*) filter (where s.id is null or f.selling_price is distinct from s.price or f.mrp is distinct from s.mrp
                              or f.inventory_units is distinct from s.inventory or f.shelf_position is distinct from s.position
                              or f.organic_position is distinct from s.organic_position
                              or coalesce(f.is_ad, false) is distinct from coalesce(s.is_ad, false)
                              or f.platform_product_id is distinct from s.external_id::text or f.snapshot_id is distinct from s.snapshot_id
                              or f.observed_at is distinct from ss.taken_at or f.platform is distinct from ss.platform::text
                              or f.city_slug is distinct from coalesce(st_.city_slug::text, scf.city_slug)) as bad
      into r
      from silver.fact_shelf_position f
      left join public.shelf_positions s on s.id = f.source_record_id
      left join public.shelf_snapshots ss on ss.id = s.snapshot_id
      left join public.stores st_ on st_.id = s.store_id
      left join ops.store_city_filled scf on scf.store_key = f.store_key
     where f.loaded_at > v_now - v_win;
    insert into ops.reconciliation_log (run_at, check_name, status, rows_checked, mismatches, detail)
    values (v_now, 'shelf_vs_bronze', case when r.bad = 0 then 'ok' else 'mismatch' end, r.n, r.bad, jsonb_build_object('window', v_win::text));
    v_bad := v_bad + r.bad;

    -- hop 2 only when dash reflects the latest successful Silver run
    select gold_status = 'success' into v_gold_ok from ops.pipeline_run
     where run_id = (select max(run_id) from ops.pipeline_run where status = 'success');
    if not coalesce(v_gold_ok, false) then
        insert into ops.reconciliation_log (run_at, check_name, status, detail)
        select v_now, c, 'skipped', jsonb_build_object('reason', 'gold not yet refreshed for the latest Silver run')
          from unnest(array['dash_pricing', 'dash_osa', 'dash_visibility', 'scorecard_totals']) c;
        return jsonb_build_object('status', case when v_bad = 0 then 'ok' else 'mismatch' end, 'mismatches', v_bad, 'dash_checks', 'skipped');
    end if;

    -- hop 2a: pricing
    with rd as (
        select f.product_key, f.store_key, f.obs_date, d.platform, coalesce(f.city_slug, '(unknown)') as city_slug, x.sidnl_id,
               f.selling_price as sp, f.mrp, f.observed_at, f.reading_key
          from silver.fact_product_reading f
          join silver.dim_product d on d.product_key = f.product_key
          join silver.dim_platform pl on pl.platform = d.platform and not pl.is_test
          join silver.product_xref x on x.product_key = f.product_key
         where f.dq_status = 'valid' and f.store_key is not null and f.selling_price is not null and f.mrp > 0),
    latest as (select distinct on (product_key, store_key, obs_date) * from rd order by product_key, store_key, obs_date, observed_at desc, reading_key desc),
    mine as (select obs_date, platform, city_slug, sidnl_id, count(distinct store_key) as stores, round(avg(mrp), 2) as mrp,
                    round(avg(sp), 2) as sp, min(sp) as mn, max(sp) as mx from latest group by 1, 2, 3, 4)
    select (select count(*) from mine) as n,
           (select count(*) from mine m full join dash.pricing p using (obs_date, platform, city_slug, sidnl_id)
             where m.sidnl_id is null or p.sidnl_id is null
                or (p.stores_observed, p.mrp, p.selling_price, p.min_selling_price, p.max_selling_price)
                   is distinct from (m.stores, m.mrp, m.sp, m.mn, m.mx)) as bad
      into r;
    insert into ops.reconciliation_log (run_at, check_name, status, rows_checked, mismatches)
    values (v_now, 'dash_pricing', case when r.bad = 0 then 'ok' else 'mismatch' end, r.n, r.bad);
    v_bad := v_bad + r.bad;

    -- hop 2b: availability OSA counts
    with mine as (
        select f.obs_date, d.platform, coalesce(f.city_slug, '(unknown)') as city_slug, x.sidnl_id,
               count(*) as oe, count(*) filter (where f.is_available) as oa
          from silver.fact_product_reading f
          join silver.dim_product d on d.product_key = f.product_key
          join silver.dim_platform pl on pl.platform = d.platform and not pl.is_test
          join silver.product_xref x on x.product_key = f.product_key
         where f.dq_status = 'valid' and f.store_key is not null and f.osa_eligible and f.is_available is not null
         group by 1, 2, 3, 4),
    dsh as (select obs_date, platform, city_slug, sidnl_id, osa_eligible_obs as oe, osa_available_obs as oa
              from dash.availability where store_key is null and osa_eligible_obs > 0)
    select (select count(*) from mine) as n,
           (select count(*) from mine m full join dsh a using (obs_date, platform, city_slug, sidnl_id)
             where m.sidnl_id is null or a.sidnl_id is null or (m.oe, m.oa) is distinct from (a.oe, a.oa)) as bad
      into r;
    insert into ops.reconciliation_log (run_at, check_name, status, rows_checked, mismatches)
    values (v_now, 'dash_osa', case when r.bad = 0 then 'ok' else 'mismatch' end, r.n, r.bad);
    v_bad := v_bad + r.bad;

    -- hop 2c: visibility category impressions
    with snap as (
        select distinct on (platform, l1_id, l2_id, store_key, obs_date) snapshot_id
          from silver.fact_shelf_position where store_key is not null
         order by platform, l1_id, l2_id, store_key, obs_date, observed_at desc, snapshot_id desc),
    mine as (
        select f.obs_date, f.platform, coalesce(f.city_slug, '(unknown)') as city_slug, f.l1_id || '>' || f.l2_id as search_term,
               x.sidnl_id, count(*) as impressions
          from silver.fact_shelf_position f
          join snap s on s.snapshot_id = f.snapshot_id
          join silver.product_xref x on x.product_key = f.product_key
          join silver.dim_platform pl on pl.platform = f.platform and not pl.is_test
         where f.dq_status = 'valid' and f.store_key is not null
         group by 1, 2, 3, 4, 5),
    dsh as (select obs_date, platform, city_slug, search_term, sidnl_id, impressions from dash.visibility where search_type = 'category')
    select (select count(*) from mine) as n,
           (select count(*) from mine m full join dsh v using (obs_date, platform, city_slug, search_term, sidnl_id)
             where m.sidnl_id is null or v.sidnl_id is null or m.impressions is distinct from v.impressions) as bad
      into r;
    insert into ops.reconciliation_log (run_at, check_name, status, rows_checked, mismatches)
    values (v_now, 'dash_visibility', case when r.bad = 0 then 'ok' else 'mismatch' end, r.n, r.bad);
    v_bad := v_bad + r.bad;

    -- scorecard totals
    select count(*) as n, count(*) filter (where s <> m) as bad into r
      from (select obs_date, platform, city_slug, sum(shelf_impressions) as s, max(market_shelf_impressions) as m
              from dash.v_brand_scorecard where market_shelf_impressions is not null group by 1, 2, 3) z;
    insert into ops.reconciliation_log (run_at, check_name, status, rows_checked, mismatches)
    values (v_now, 'scorecard_totals', case when r.bad = 0 then 'ok' else 'mismatch' end, r.n, r.bad);
    v_bad := v_bad + r.bad;

    if v_bad > 0 then
        insert into ops.cron_alert_log (jobname, level, consecutive_failures, last_failure_message)
        values ('sidnl-reconcile:data', 'alert', 1,
                left('reconciliation mismatches: ' || (select string_agg(check_name || '=' || mismatches, ', ')
                                                         from ops.reconciliation_log where run_at = v_now and status = 'mismatch'), 500));
    end if;
    return jsonb_build_object('status', case when v_bad = 0 then 'ok' else 'mismatch' end, 'mismatches', v_bad);
end $function$
;

CREATE OR REPLACE FUNCTION silver.reconcile_coverage()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare v_n bigint; v_bad bigint; v_now timestamptz := now();
begin
    select count(*), count(*) filter (where f.source_record_id is null and dl.bronze_id is null)
      into v_n, v_bad
      from public.shelf_positions sp
      join public.shelf_snapshots sn on sn.id = sp.snapshot_id and sn.status = 'ok'
      join silver.category_scope cs on cs.platform = sn.platform and cs.l1_id = sn.l1_id and cs.l2_id = sn.l2_id
                                   and cs.is_enabled and sp.id <= cs.last_loaded_id
      join silver.dim_platform pl on pl.platform = sn.platform and not pl.is_test
      left join silver.fact_shelf_position f on f.source_record_id = sp.id
      left join ops.dead_letter dl on dl.source_table = 'public.shelf_positions' and dl.bronze_id = sp.id and dl.status in ('open', 'ignored');
    insert into ops.reconciliation_log (run_at, check_name, status, rows_checked, mismatches, detail)
    values (v_now, 'shelf_rows_accounted', case when v_bad = 0 then 'ok' else 'mismatch' end, v_n, v_bad,
            jsonb_build_object('open_dead_letters', (select count(*) from ops.dead_letter where status = 'open'),
                               'ignored_dead_letters', (select count(*) from ops.dead_letter where status = 'ignored')));
    if v_bad > 0 then
        insert into ops.cron_alert_log (jobname, level, consecutive_failures, last_failure_message)
        values ('sidnl-reconcile:coverage', 'alert', 1, format('%s bronze shelf rows below their scope watermark are neither in silver nor dead-lettered', v_bad));
    end if;
    return jsonb_build_object('rows_checked', v_n, 'unaccounted', v_bad);
end $function$
;

CREATE OR REPLACE FUNCTION silver.record_storage_snapshot()
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare v_d date := (now() at time zone 'Asia/Kolkata')::date; v_n int := 0;
begin
  begin perform silver.check_storage_alert(); exception when others then raise warning 'check_storage_alert failed: %', sqlerrm; end;
  begin perform silver.check_cron_alert();    exception when others then raise warning 'check_cron_alert failed: %', sqlerrm; end;
  if exists (select 1 from ops.storage_snapshot where snapshot_date = v_d) then return 0; end if;
  insert into ops.storage_snapshot (snapshot_date, relation, total_bytes, table_bytes, index_bytes, live_rows, dead_rows, db_bytes)
  select v_d, n.nspname || '.' || c.relname, pg_total_relation_size(c.oid), pg_relation_size(c.oid), pg_indexes_size(c.oid),
         s.n_live_tup, s.n_dead_tup, pg_database_size(current_database())
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    left join pg_stat_all_tables s on s.relid = c.oid
   where c.relkind = 'r' and n.nspname in ('silver','public') and pg_total_relation_size(c.oid) > 1024*1024
  on conflict do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $function$
;

CREATE OR REPLACE FUNCTION silver.refresh_all()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare r record; v_out jsonb := '{}'::jsonb;
begin
    for r in select brand_key from silver.brand_scope where is_enabled order by brand_key loop
        v_out := v_out || jsonb_build_object(r.brand_key, silver.refresh_brand(r.brand_key));
    end loop;
    v_out := v_out || jsonb_build_object('category_market', silver.refresh_category_market());
    return v_out;
end
$function$
;

CREATE OR REPLACE FUNCTION silver.refresh_brand(p_brand_key text DEFAULT 'mr munchies'::text, p_full boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare
    v_scope  silver.brand_scope%rowtype;
    v_run    bigint;
    v_stats  jsonb := '{}'::jsonb;
    v_ins    int;
    v_upd    int;
    v_full   boolean;
    v_lb     bigint := coalesce(silver.cfg('incremental_lookback_rows'), 5000)::bigint;
    w_obs bigint := 0; w_sc bigint := 0; w_sp bigint := 0; w_ssn bigint := 0;
begin
    select * into v_scope from silver.brand_scope where brand_key = p_brand_key;
    if not found then
        raise exception 'unknown brand_key "%": add it to silver.brand_scope first', p_brand_key;
    end if;
    if not v_scope.is_enabled then
        raise exception 'brand "%" is disabled in silver.brand_scope', p_brand_key;
    end if;

    v_full := p_full or not exists (select 1 from ops.etl_run where brand_key = p_brand_key and status = 'success');
    if not v_full then
        select coalesce(greatest(max(last_seen_id) filter (where source_table = 'observations')     - v_lb, 0), 0),
               coalesce(greatest(max(last_seen_id) filter (where source_table = 'search_cards')      - v_lb, 0), 0),
               coalesce(greatest(max(last_seen_id) filter (where source_table = 'shelf_positions')   - v_lb, 0), 0),
               coalesce(greatest(max(last_seen_id) filter (where source_table = 'search_snapshots')  - v_lb, 0), 0)
          into w_obs, w_sc, w_sp, w_ssn
          from silver.pipeline_source where source_schema = 'public';
    end if;

    insert into ops.etl_run (brand_key) values (p_brand_key) returning run_id into v_run;

    drop table if exists _brand_strings, _listings, _raw, _store_ids, _scans,
                         _cat_src, _cat_best, _prod_src, _prod;

    perform silver.refresh_brand_strings(v_full);

    insert into silver.dim_city (city_slug, city_name, state, center_lat, center_lon)
    select c.slug, c.name, c.state, c.center_lat, c.center_lon from public.cities c
    on conflict (city_slug) do update set
        city_name = excluded.city_name, state = excluded.state,
        center_lat = excluded.center_lat, center_lon = excluded.center_lon
    where (silver.dim_city.city_name, silver.dim_city.state, silver.dim_city.center_lat, silver.dim_city.center_lon)
          is distinct from (excluded.city_name, excluded.state, excluded.center_lat, excluded.center_lon);

    insert into silver.dim_brand (brand_key, brand_name, company_name, is_tracked)
    values (v_scope.brand_key, v_scope.brand_name, v_scope.company_name, true)
    on conflict (brand_key) do update set
        brand_name = excluded.brand_name, company_name = excluded.company_name
    where (silver.dim_brand.brand_name, silver.dim_brand.company_name)
          is distinct from (excluded.brand_name, excluded.company_name);

    create temp table _brand_strings on commit drop as
    select raw_brand as b from silver.brand_string_registry
    where silver.brand_matches(p_brand_key, raw_brand);

    create temp table _listings on commit drop as
    select pl.id                                   as listing_id,
           pl.platform,
           pl.external_id,
           coalesce(pl.name, p.name)               as name,
           coalesce(pl.brand, p.brand)             as brand,
           pl.pack_size,
           coalesce(pl.image_url, p.image_url)     as image_url,
           pl.url,
           pl.product_id                           as catalog_product_id,
           pl.categories::jsonb                    as categories
    from public.platform_listings pl
    join public.products p on p.id = pl.product_id
    where coalesce(pl.brand, p.brand) in (select b from _brand_strings)
      and pl.platform in (select platform from silver.dim_platform where not is_test);

    create temp table _scans on commit drop as
    select ss.*
    from public.search_snapshots ss
    join public.brand_scrapes bs on bs.id = ss.scrape_id
    where ss.id > w_ssn
      and ss.platform in (select platform from silver.dim_platform where not is_test)
      and exists (select 1
                  from json_array_elements_text(
                           case when json_typeof(bs.brands) = 'array' then bs.brands else '[]'::json end) x(v)
                  where silver.brand_matches(p_brand_key, x.v));

    create temp table _raw on commit drop as
    select 'stock_check'::text            as source_type,
           'public.observations'::text    as source_table,
           o.id                           as source_record_id,
           l.platform,
           l.external_id                  as platform_product_id,
           o.store_id                     as src_store_id,
           null::int                      as planned_store_id,
           ('stock_check:' || o.run_id)   as job_ref,
           o.run_id::int                  as run_id,
           null::int                      as scrape_id,
           null::bigint                   as snapshot_id,
           l.listing_id                   as listing_id,
           o.observed_at,
           o.state,
           o.inventory,
           o.inventory_capped,
           o.price::numeric               as price,
           o.mrp::numeric                 as mrp,
           null::int                      as pos,
           null::int                      as opos,
           null::boolean                  as is_ad,
           null::text                     as ad_type,
           null::text                     as ptype,
           null::text                     as name,
           null::text                     as brand,
           null::text                     as pack,
           null::text                     as image_url
    from public.observations o
    join _listings l on l.listing_id = o.listing_id
    where o.id > w_obs

    union all
    select 'brand_search', 'public.search_cards', c.id,
           ss.platform, c.external_id,
           coalesce(c.store_id, ss.store_id, ss.planned_store_id),
           ss.planned_store_id,
           ('brand_scrape:' || ss.scrape_id),
           null::int, ss.scrape_id::int, ss.id::bigint, null::int,
           ss.taken_at, c.state, c.inventory, c.inventory_capped,
           c.price::numeric, c.mrp::numeric,
           c."position", c.organic_position, c.is_ad, null::text,
           pp.ptype, pp.name, pp.brand, pp.pack, pp.image_url
    from public.search_cards c
    join public.search_snapshots ss on ss.id = c.snapshot_id
    join public.platform_products pp on pp.platform = ss.platform and pp.external_id = c.external_id
    where c.id > w_sc
      and pp.brand in (select b from _brand_strings)
      and ss.platform in (select platform from silver.dim_platform where not is_test)

    union all
    select 'category_shelf', 'public.shelf_positions', sp.id,
           sn.platform, sp.external_id,
           coalesce(sp.store_id, sn.store_id),
           sn.store_id,
           case when sn.sweep_id is not null then 'category_sweep:' || sn.sweep_id
                else 'shelf_snapshot:' || sn.id end,
           null::int, null::int, sn.id::bigint, null::int,
           sn.taken_at, sp.state, sp.inventory, sp.inventory_capped,
           sp.price::numeric, sp.mrp::numeric,
           sp."position", sp.organic_position, sp.is_ad, sp.ad_type,
           pp.ptype, pp.name, pp.brand, pp.pack, pp.image_url
    from public.shelf_positions sp
    join public.shelf_snapshots sn on sn.id = sp.snapshot_id
    join public.platform_products pp on pp.platform = sn.platform and pp.external_id = sp.external_id
    where sp.id > w_sp
      and pp.brand in (select b from _brand_strings)
      and sn.platform in (select platform from silver.dim_platform where not is_test);

    create temp table _store_ids on commit drop as
    select src_store_id as id from _raw where src_store_id is not null
    union select planned_store_id from _raw where planned_store_id is not null
    union select store_id from _scans where store_id is not null
    union select planned_store_id from _scans where planned_store_id is not null;

    with ins as (
        insert into silver.dim_store (platform, store_external_id, source_store_id, store_name,
                                      city_slug, latitude, longitude, first_seen_at, last_seen_at)
        select s.platform, s.external_id, s.id, s.name, s.city_slug, s.lat, s.lon,
               s.first_seen_at, s.last_seen_at
        from public.stores s
        where s.id in (select id from _store_ids)
          and s.platform in (select platform from silver.dim_platform)
        on conflict (source_store_id) do update set
            store_name = excluded.store_name, city_slug = coalesce(excluded.city_slug, silver.dim_store.city_slug),
            latitude = excluded.latitude, longitude = excluded.longitude,
            first_seen_at = excluded.first_seen_at, last_seen_at = excluded.last_seen_at
        where (silver.dim_store.store_name, silver.dim_store.city_slug, silver.dim_store.latitude, silver.dim_store.longitude, silver.dim_store.first_seen_at, silver.dim_store.last_seen_at)
              is distinct from (excluded.store_name, coalesce(excluded.city_slug, silver.dim_store.city_slug), excluded.latitude, excluded.longitude, excluded.first_seen_at, excluded.last_seen_at)
        returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;
    v_stats := v_stats || jsonb_build_object('dim_store', jsonb_build_object('inserted', v_ins, 'updated', v_upd));

    create temp table _cat_src on commit drop as
    select l.platform, l.external_id as platform_product_id, 1 as prio,
           l.categories -> 0 ->> 'id'   as l1_id, l.categories -> 0 ->> 'name' as l1_name,
           l.categories -> 1 ->> 'id'   as l2_id, l.categories -> 1 ->> 'name' as l2_name,
           l.categories -> 2 ->> 'id'   as l3_id, l.categories -> 2 ->> 'name' as l3_name
    from _listings l
    where jsonb_typeof(l.categories) = 'array' and jsonb_array_length(l.categories) >= 1
    union all
    select pc.platform::text, pc.product_id::text, 2,
           pc.category_l1_id::text, c.category_l1,
           pc.category_l2_id::text, c.category_l2,
           null, null
    from analytics.product_categories pc
    left join analytics.categories c
           on c.platform = pc.platform
          and c.category_l1_id = pc.category_l1_id
          and c.category_l2_id = pc.category_l2_id
    where (pc.platform::text, pc.product_id::text) in
          (select platform, platform_product_id from _raw);

    create temp table _cat_best on commit drop as
    select distinct on (platform, platform_product_id)
           platform, platform_product_id, l1_id, l1_name, l2_id, l2_name, l3_id, l3_name
    from _cat_src
    where l1_name is not null
    order by platform, platform_product_id, prio;

    insert into silver.dim_category (platform, l1_id, l1_name, l2_id, l2_name, l3_id, l3_name)
    select distinct platform, l1_id, l1_name, l2_id, l2_name, l3_id, l3_name from _cat_best
    on conflict do nothing;

    create temp table _prod_src on commit drop as
    select l.platform, l.external_id as pid, 1 as prio, now() as seen_at,
           l.name, l.brand, l.pack_size as pack, null::text as ptype, l.image_url, l.url,
           l.listing_id, l.catalog_product_id
    from _listings l
    union all
    select r.platform, r.platform_product_id, case r.source_type when 'brand_search' then 2 else 3 end,
           r.observed_at, r.name, r.brand, r.pack, r.ptype, r.image_url, null::text, null::int, null::int
    from _raw r where r.source_type <> 'stock_check';

    create temp table _prod on commit drop as
    select platform, pid,
           (array_agg(name       order by prio, seen_at desc) filter (where name is not null))[1]       as name,
           (array_agg(brand      order by prio, seen_at desc) filter (where brand is not null))[1]      as brand,
           (array_agg(pack       order by prio, seen_at desc) filter (where pack is not null))[1]       as pack,
           (array_agg(ptype      order by prio, seen_at desc) filter (where ptype is not null))[1]      as ptype,
           (array_agg(image_url  order by prio, seen_at desc) filter (where image_url is not null))[1]  as image_url,
           (array_agg(url        order by prio, seen_at desc) filter (where url is not null))[1]        as url,
           (array_agg(listing_id order by prio, seen_at desc) filter (where listing_id is not null))[1] as listing_id,
           (array_agg(catalog_product_id order by prio, seen_at desc)
                                                              filter (where catalog_product_id is not null))[1] as catalog_product_id
    from _prod_src
    group by platform, pid;

    with ins as (
        insert into silver.dim_product (platform, platform_product_id, brand_key, product_name, variant,
                                        product_type, pack_raw, size_value, size_unit, pack_count,
                                        category_key, listing_id, catalog_product_id, image_url, product_url)
        select p.platform, p.pid, p_brand_key,
               coalesce(p.name, 'Unknown product ' || p.pid),
               silver.parse_variant(p.name, p.brand, p.ptype),
               p.ptype, p.pack, pk.size_value, pk.size_unit, pk.pack_count,
               dc.category_key, p.listing_id, p.catalog_product_id, p.image_url, p.url
        from _prod p
        cross join lateral silver.parse_pack(p.pack) pk
        left join _cat_best cb on cb.platform = p.platform and cb.platform_product_id = p.pid
        left join silver.dim_category dc
               on dc.platform = cb.platform
              and dc.l1_id   is not distinct from cb.l1_id   and dc.l1_name is not distinct from cb.l1_name
              and dc.l2_id   is not distinct from cb.l2_id   and dc.l2_name is not distinct from cb.l2_name
              and dc.l3_id   is not distinct from cb.l3_id   and dc.l3_name is not distinct from cb.l3_name
        on conflict (platform, platform_product_id) do update set
            brand_key = excluded.brand_key, product_name = excluded.product_name,
            variant = excluded.variant, product_type = coalesce(excluded.product_type, silver.dim_product.product_type),
            pack_raw = excluded.pack_raw, size_value = excluded.size_value, size_unit = excluded.size_unit,
            pack_count = excluded.pack_count,
            category_key = coalesce(excluded.category_key, silver.dim_product.category_key),
            listing_id = coalesce(excluded.listing_id, silver.dim_product.listing_id),
            catalog_product_id = coalesce(excluded.catalog_product_id, silver.dim_product.catalog_product_id),
            image_url = coalesce(excluded.image_url, silver.dim_product.image_url),
            product_url = coalesce(excluded.product_url, silver.dim_product.product_url)
        where (silver.dim_product.brand_key, silver.dim_product.product_name, silver.dim_product.variant, silver.dim_product.product_type,
               silver.dim_product.pack_raw, silver.dim_product.size_value, silver.dim_product.size_unit, silver.dim_product.pack_count,
               silver.dim_product.category_key, silver.dim_product.listing_id, silver.dim_product.catalog_product_id,
               silver.dim_product.image_url, silver.dim_product.product_url)
              is distinct from
              (excluded.brand_key, excluded.product_name, excluded.variant, coalesce(excluded.product_type, silver.dim_product.product_type),
               excluded.pack_raw, excluded.size_value, excluded.size_unit, excluded.pack_count,
               coalesce(excluded.category_key, silver.dim_product.category_key), coalesce(excluded.listing_id, silver.dim_product.listing_id),
               coalesce(excluded.catalog_product_id, silver.dim_product.catalog_product_id),
               coalesce(excluded.image_url, silver.dim_product.image_url), coalesce(excluded.product_url, silver.dim_product.product_url))
        returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;
    v_stats := v_stats || jsonb_build_object('dim_product', jsonb_build_object('inserted', v_ins, 'updated', v_upd));

    with ins as (
        insert into silver.fact_product_reading (
            source_type, source_table, source_record_id, product_key, store_key, planned_store_key,
            city_slug, job_ref, run_id, scrape_id, snapshot_id, listing_id, observed_at,
            stock_state_raw, stock_status, is_listed, is_available, inventory_units, inventory_is_capped,
            selling_price, mrp, search_position, organic_position, is_ad, ad_type,
            osa_eligible, dq_status, dq_flags, etl_run_id)
        select r.source_type, r.source_table, r.source_record_id, dp.product_key, ds.store_key, dps.store_key,
               ds.city_slug, r.job_ref, r.run_id, r.scrape_id, r.snapshot_id, r.listing_id, r.observed_at,
               r.state, q.status, q.status <> 'not_listed',
               case q.status when 'in_stock' then true when 'out_of_stock' then false end,
               r.inventory, coalesce(r.inventory_capped, false),
               round(r.price, 2), round(r.mrp, 2), r.pos, r.opos, r.is_ad, r.ad_type,
               (r.source_type = 'stock_check' and q.status in ('in_stock', 'out_of_stock')
                                              and silver.dq_status(q.flags) = 'valid'),
               silver.dq_status(q.flags), q.flags, v_run
        from _raw r
        join silver.dim_product dp on dp.platform = r.platform and dp.platform_product_id = r.platform_product_id
        left join silver.dim_store ds  on ds.source_store_id  = r.src_store_id
        left join silver.dim_store dps on dps.source_store_id = r.planned_store_id
        cross join lateral (
            select silver.map_stock_status(r.state) as status,
                   silver.reading_dq(true, ds.store_key is not null, r.observed_at,
                                     silver.map_stock_status(r.state), r.inventory,
                                     round(r.price, 2), round(r.mrp, 2)) as flags) q
        on conflict (source_type, source_record_id) do update set
            product_key = excluded.product_key, store_key = excluded.store_key,
            planned_store_key = excluded.planned_store_key, city_slug = excluded.city_slug,
            job_ref = excluded.job_ref, run_id = excluded.run_id, scrape_id = excluded.scrape_id,
            snapshot_id = excluded.snapshot_id, listing_id = excluded.listing_id,
            observed_at = excluded.observed_at, stock_state_raw = excluded.stock_state_raw,
            stock_status = excluded.stock_status, is_listed = excluded.is_listed,
            is_available = excluded.is_available, inventory_units = excluded.inventory_units,
            inventory_is_capped = excluded.inventory_is_capped, selling_price = excluded.selling_price,
            mrp = excluded.mrp, search_position = excluded.search_position,
            organic_position = excluded.organic_position, is_ad = excluded.is_ad, ad_type = excluded.ad_type,
            osa_eligible = excluded.osa_eligible, dq_status = excluded.dq_status, dq_flags = excluded.dq_flags,
            loaded_at = now(), etl_run_id = excluded.etl_run_id
        where (silver.fact_product_reading.product_key, silver.fact_product_reading.store_key, silver.fact_product_reading.planned_store_key,
               silver.fact_product_reading.city_slug, silver.fact_product_reading.job_ref, silver.fact_product_reading.run_id,
               silver.fact_product_reading.scrape_id, silver.fact_product_reading.snapshot_id, silver.fact_product_reading.listing_id,
               silver.fact_product_reading.observed_at, silver.fact_product_reading.stock_state_raw, silver.fact_product_reading.stock_status,
               silver.fact_product_reading.is_listed, silver.fact_product_reading.is_available, silver.fact_product_reading.inventory_units,
               silver.fact_product_reading.inventory_is_capped, silver.fact_product_reading.selling_price, silver.fact_product_reading.mrp,
               silver.fact_product_reading.search_position, silver.fact_product_reading.organic_position, silver.fact_product_reading.is_ad,
               silver.fact_product_reading.ad_type, silver.fact_product_reading.osa_eligible, silver.fact_product_reading.dq_status,
               silver.fact_product_reading.dq_flags)
              is distinct from
              (excluded.product_key, excluded.store_key, excluded.planned_store_key, excluded.city_slug, excluded.job_ref, excluded.run_id,
               excluded.scrape_id, excluded.snapshot_id, excluded.listing_id, excluded.observed_at, excluded.stock_state_raw, excluded.stock_status,
               excluded.is_listed, excluded.is_available, excluded.inventory_units, excluded.inventory_is_capped, excluded.selling_price, excluded.mrp,
               excluded.search_position, excluded.organic_position, excluded.is_ad, excluded.ad_type, excluded.osa_eligible, excluded.dq_status,
               excluded.dq_flags)
        returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;
    v_stats := v_stats || jsonb_build_object('fact_product_reading', jsonb_build_object('inserted', v_ins, 'updated', v_upd));

    with ins as (
        insert into silver.fact_store_scan (
            snapshot_id, scrape_id, scrape_query, platform, brand_key, store_key, planned_store_key,
            city_slug, scanned_at, scan_status, pages_read, cards_seen, brand_cards_matched,
            is_complete, stopped_early, is_valid_denominator, dq_flags, etl_run_id)
        select s.id, s.scrape_id, bs.query, s.platform, p_brand_key, ds.store_key, dps.store_key,
               coalesce(ds.city_slug, dps.city_slug), s.taken_at, s.status, s.pages_read, s.cards_seen,
               s.cards_matched, s.complete, s.stopped_early,
               (s.status = 'ok' and ds.store_key is not null),
               array_remove(array[
                   case when ds.store_key is null then 'no_store' end,
                   case when s.status <> 'ok' then 'scan_' || s.status end,
                   case when s.store_id is not null and s.store_id is distinct from s.planned_store_id
                        then 'info_store_differs_from_planned' end], null),
               v_run
        from _scans s
        left join public.brand_scrapes bs on bs.id = s.scrape_id
        left join silver.dim_store ds  on ds.source_store_id  = s.store_id
        left join silver.dim_store dps on dps.source_store_id = s.planned_store_id
        on conflict (snapshot_id) do update set
            scrape_query = excluded.scrape_query, store_key = excluded.store_key,
            planned_store_key = excluded.planned_store_key, city_slug = excluded.city_slug,
            scanned_at = excluded.scanned_at, scan_status = excluded.scan_status,
            pages_read = excluded.pages_read, cards_seen = excluded.cards_seen,
            brand_cards_matched = excluded.brand_cards_matched, is_complete = excluded.is_complete,
            stopped_early = excluded.stopped_early, is_valid_denominator = excluded.is_valid_denominator,
            dq_flags = excluded.dq_flags, loaded_at = now(), etl_run_id = excluded.etl_run_id
        where (silver.fact_store_scan.scrape_query, silver.fact_store_scan.store_key, silver.fact_store_scan.planned_store_key,
               silver.fact_store_scan.city_slug, silver.fact_store_scan.scanned_at, silver.fact_store_scan.scan_status, silver.fact_store_scan.pages_read,
               silver.fact_store_scan.cards_seen, silver.fact_store_scan.brand_cards_matched, silver.fact_store_scan.is_complete,
               silver.fact_store_scan.stopped_early, silver.fact_store_scan.dq_flags)
              is distinct from
              (excluded.scrape_query, excluded.store_key, excluded.planned_store_key, excluded.city_slug, excluded.scanned_at, excluded.scan_status,
               excluded.pages_read, excluded.cards_seen, excluded.brand_cards_matched, excluded.is_complete, excluded.stopped_early, excluded.dq_flags)
        returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;
    v_stats := v_stats || jsonb_build_object('fact_store_scan', jsonb_build_object('inserted', v_ins, 'updated', v_upd));

    update silver.dim_product p
       set first_seen_at = x.mn, last_seen_at = x.mx
      from (select f.product_key, min(f.observed_at) mn, max(f.observed_at) mx
              from silver.fact_product_reading f
             where f.product_key in (select dp.product_key
                                       from silver.dim_product dp
                                       join _prod t on t.platform = dp.platform and t.pid = dp.platform_product_id)
             group by f.product_key) x
     where x.product_key = p.product_key
       and (p.first_seen_at, p.last_seen_at) is distinct from (x.mn, x.mx);

    v_stats := v_stats || jsonb_build_object('brand_key', p_brand_key, 'run_id', v_run, 'mode',
                                             case when v_full then 'full' else 'incremental' end);
    if v_full then
        v_stats := v_stats || jsonb_build_object(
            'dq', (select coalesce(jsonb_object_agg(dq_status, n), '{}'::jsonb)
                     from (select f.dq_status, count(*) n
                             from silver.fact_product_reading f
                             join silver.dim_product p using (product_key)
                            where p.brand_key = p_brand_key group by 1) d));
    end if;

    update ops.etl_run set finished_at = now(), status = 'success', stats = v_stats where run_id = v_run;
    return v_stats;
end
$function$
;

CREATE OR REPLACE FUNCTION silver.refresh_brand_strings(p_full boolean DEFAULT false)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION silver.refresh_category_market(p_full boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare
    sc record; v_key text; v_s jsonb; v_scopes jsonb := '{}'::jsonb; v_failed jsonb := '[]'::jsonb;
    v_ins bigint := 0; v_upd bigint := 0;
begin
    insert into silver.dim_city (city_slug, city_name, state, center_lat, center_lon)
    select c.slug, c.name, c.state, c.center_lat, c.center_lon from public.cities c
    on conflict (city_slug) do update set
        city_name = excluded.city_name, state = excluded.state,
        center_lat = excluded.center_lat, center_lon = excluded.center_lon
    where (silver.dim_city.city_name, silver.dim_city.state, silver.dim_city.center_lat, silver.dim_city.center_lon)
          is distinct from (excluded.city_name, excluded.state, excluded.center_lat, excluded.center_lon);

    for sc in select platform, l1_id, l2_id from silver.category_scope where is_enabled order by 1, 2, 3 loop
        v_key := sc.platform || '/' || sc.l1_id || '/' || sc.l2_id;
        begin
            v_s := silver.refresh_category_scope(sc.platform, sc.l1_id, sc.l2_id, p_full);
            v_scopes := v_scopes || jsonb_build_object(v_key, v_s || jsonb_build_object('ok', true));
            v_ins := v_ins + coalesce((v_s -> 'fact_shelf_position' ->> 'inserted')::bigint, 0);
            v_upd := v_upd + coalesce((v_s -> 'fact_shelf_position' ->> 'updated')::bigint, 0);
        exception when others then
            v_failed := v_failed || to_jsonb(v_key);
            v_scopes := v_scopes || jsonb_build_object(v_key, jsonb_build_object('ok', false, 'error', sqlerrm, 'sqlstate', sqlstate));
            update silver.category_scope set last_status = 'failed', last_error = left(sqlerrm, 500),
                   consecutive_failures = consecutive_failures + 1
             where platform = sc.platform and l1_id = sc.l1_id and l2_id = sc.l2_id;
        end;
    end loop;
    return jsonb_build_object('mode', case when p_full then 'full' else 'incremental' end,
                              'scopes', v_scopes, 'failed_scopes', v_failed,
                              'fact_shelf_position', jsonb_build_object('inserted', v_ins, 'updated', v_upd));
end $function$
;

CREATE OR REPLACE FUNCTION silver.refresh_category_products(p_run bigint, p_lo bigint, p_hi bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare v_b int; v_ins int; v_upd int; v_k int;
begin
    drop table if exists _cp_rows, _cp, _cp_brand;

    create temp table _cp_rows on commit drop as
    select f.source_record_id, f.platform, f.platform_product_id, f.l1_id, f.l2_id, f.brand_key, f.brand_raw,
           f.product_name, f.pack_raw, f.observed_at, pp.ptype, pp.image_url
    from silver.fact_shelf_position f
    left join public.platform_products pp on pp.platform = f.platform and pp.external_id = f.platform_product_id
    where f.source_record_id > p_lo and f.source_record_id <= p_hi
      and f.platform_product_id is not null and (f.etl_run_id = p_run or f.product_key is null);

    create temp table _cp_brand on commit drop as
    select distinct on (brand_key) brand_key, brand_raw
      from (select brand_key, brand_raw, count(*) n from _cp_rows where brand_key is not null group by 1, 2) z
     order by brand_key, n desc, brand_raw;

    insert into silver.brand_scope (brand_key, brand_name, company_name, raw_brand_aliases, is_enabled, scope_source)
    select b.brand_key, coalesce(b.brand_raw, b.brand_key), null, array[coalesce(b.brand_raw, b.brand_key)], false, 'category_shelf'
    from _cp_brand b
    on conflict (brand_key) do nothing;

    with ins as (
        insert into silver.dim_brand (brand_key, brand_name, company_name, is_tracked)
        select b.brand_key, coalesce(b.brand_raw, b.brand_key), null, false from _cp_brand b
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
     where f.source_record_id > p_lo and f.source_record_id <= p_hi and (f.etl_run_id = p_run or f.product_key is null)
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
$function$
;

CREATE OR REPLACE FUNCTION silver.refresh_category_scope(p_platform text, p_l1 text, p_l2 text, p_full boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare
    v_run bigint; v_c jsonb;
    v_tot_ins int := 0; v_tot_upd int := 0; v_tot_stores int := 0; v_dl int := 0;
    v_pb int := 0; v_pi int := 0; v_pu int := 0; v_pl int := 0; v_stats jsonb;
    v_lb   bigint := coalesce(silver.cfg('incremental_lookback_rows'), 5000)::bigint;
    v_step bigint := coalesce(silver.cfg('category_chunk_rows'), 50000)::bigint;
    v_wm bigint; v_start bigint; v_max bigint; v_lo bigint; v_hi bigint; v_loaded boolean;
begin
    select cs.last_loaded_id into v_wm from silver.category_scope cs
     where cs.platform = p_platform and cs.l1_id = p_l1 and cs.l2_id = p_l2 and cs.is_enabled;
    if not found then return jsonb_build_object('skipped', 'scope not enabled', 'max_id', null); end if;
    v_loaded := exists (select 1 from silver.fact_shelf_position f where f.platform = p_platform and f.l1_id = p_l1 and f.l2_id = p_l2);
    select coalesce(max(id), 0) into v_max from public.shelf_positions;
    if not p_full and v_loaded and v_wm is not null and v_max <= v_wm then
        return jsonb_build_object('skipped', 'no new bronze rows', 'max_id', v_wm,
                                  'fact_shelf_position', jsonb_build_object('inserted', 0, 'updated', 0));
    end if;
    v_start := case when p_full or v_wm is null or not v_loaded then 0 else greatest(v_wm - v_lb, 0) end;

    insert into ops.etl_run (brand_key) values ('(category:' || p_platform || '/' || p_l1 || '/' || p_l2 || ')') returning run_id into v_run;

    v_lo := v_start;
    while v_lo < v_max loop
        v_hi := v_lo + v_step;
        perform set_config('sidnl.dl_count', '0', true);
        v_c := silver.load_category_range(p_platform, p_l1, p_l2, v_lo, v_hi, v_run);
        v_tot_stores := v_tot_stores + coalesce((v_c ->> 'stores')::int, 0);
        v_tot_ins := v_tot_ins + coalesce((v_c ->> 'ins')::int, 0);
        v_tot_upd := v_tot_upd + coalesce((v_c ->> 'upd')::int, 0);
        v_pb := v_pb + coalesce((v_c ->> 'pb')::int, 0); v_pi := v_pi + coalesce((v_c ->> 'pi')::int, 0);
        v_pu := v_pu + coalesce((v_c ->> 'pu')::int, 0); v_pl := v_pl + coalesce((v_c ->> 'pl')::int, 0);
        v_dl := v_dl + coalesce((v_c ->> 'dead_lettered')::int, 0);
        v_lo := v_hi;
    end loop;

    v_stats := jsonb_build_object(
        'mode', case when p_full then 'full' when not v_loaded then 'new_category' else 'incremental' end,
        'max_id', v_max, 'dim_store_added', v_tot_stores,
        'fact_shelf_position', jsonb_build_object('inserted', v_tot_ins, 'updated', v_tot_upd),
        'dim_brand_added', v_pb, 'dim_product', jsonb_build_object('inserted', v_pi, 'updated', v_pu),
        'shelf_rows_linked', v_pl, 'dead_lettered', v_dl, 'run_id', v_run);
    update ops.etl_run set finished_at = now(), status = 'success', stats = v_stats where run_id = v_run;
    return v_stats;
end $function$
;

CREATE OR REPLACE FUNCTION silver.refresh_freshness()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare
    v_lb bigint := coalesce(silver.cfg('freshness_lookback_rows'), 1000)::bigint;
    v_lo bigint; v_max bigint; v_ev int := 0;
begin
    if not pg_try_advisory_xact_lock(727103) then
        return jsonb_build_object('status', 'skipped', 'reason', 'already running');
    end if;

    -- category_shelf <- public.shelf_snapshots
    select greatest(coalesce((select last_id from ops.freshness_cursor where source_table = 'public.shelf_snapshots'), 0) - v_lb, 0) into v_lo;
    select coalesce(max(id), 0) into v_max from public.shelf_snapshots;
    insert into ops.freshness_state as t (platform, source_type, last_ok_at, last_attempt_at, last_failed_at, updated_at)
    select lower(btrim(platform::text)), 'category_shelf',
           max(taken_at) filter (where status in ('ok', 'empty')), max(taken_at), max(taken_at) filter (where status = 'failed'), now()
      from public.shelf_snapshots where id > v_lo and id <= v_max and platform is not null
     group by 1
    on conflict (platform, source_type) do update set
        last_ok_at      = greatest(t.last_ok_at, excluded.last_ok_at),
        last_attempt_at = greatest(t.last_attempt_at, excluded.last_attempt_at),
        last_failed_at  = greatest(t.last_failed_at, excluded.last_failed_at),
        updated_at      = now();
    insert into ops.freshness_cursor (source_table, last_id) values ('public.shelf_snapshots', v_max)
    on conflict (source_table) do update set last_id = greatest(ops.freshness_cursor.last_id, excluded.last_id), updated_at = now();

    -- brand_search <- public.search_snapshots
    select greatest(coalesce((select last_id from ops.freshness_cursor where source_table = 'public.search_snapshots'), 0) - v_lb, 0) into v_lo;
    select coalesce(max(id), 0) into v_max from public.search_snapshots;
    insert into ops.freshness_state as t (platform, source_type, last_ok_at, last_attempt_at, last_failed_at, updated_at)
    select lower(btrim(platform::text)), 'brand_search',
           max(taken_at) filter (where status in ('ok', 'empty')), max(taken_at), max(taken_at) filter (where status = 'failed'), now()
      from public.search_snapshots where id > v_lo and id <= v_max and platform is not null
     group by 1
    on conflict (platform, source_type) do update set
        last_ok_at      = greatest(t.last_ok_at, excluded.last_ok_at),
        last_attempt_at = greatest(t.last_attempt_at, excluded.last_attempt_at),
        last_failed_at  = greatest(t.last_failed_at, excluded.last_failed_at),
        updated_at      = now();
    insert into ops.freshness_cursor (source_table, last_id) values ('public.search_snapshots', v_max)
    on conflict (source_table) do update set last_id = greatest(ops.freshness_cursor.last_id, excluded.last_id), updated_at = now();

    -- stock_check <- public.observations (platform from its listing)
    select greatest(coalesce((select last_id from ops.freshness_cursor where source_table = 'public.observations'), 0) - v_lb, 0) into v_lo;
    select coalesce(max(id), 0) into v_max from public.observations;
    insert into ops.freshness_state as t (platform, source_type, last_ok_at, last_attempt_at, updated_at)
    select lower(btrim(l.platform::text)), 'stock_check', max(o.observed_at), max(o.observed_at), now()
      from public.observations o join public.platform_listings l on l.id = o.listing_id
     where o.id > v_lo and o.id <= v_max and l.platform is not null
     group by 1
    on conflict (platform, source_type) do update set
        last_ok_at      = greatest(t.last_ok_at, excluded.last_ok_at),
        last_attempt_at = greatest(t.last_attempt_at, excluded.last_attempt_at),
        updated_at      = now();
    insert into ops.freshness_cursor (source_table, last_id) values ('public.observations', v_max)
    on conflict (source_table) do update set last_id = greatest(ops.freshness_cursor.last_id, excluded.last_id), updated_at = now();

    -- status changes -> event log (+ alert row when something goes stale)
    with cur as (select platform, source_type, status, last_ok_at from dash.v_data_freshness),
    chg as (
        select c.*, s.last_status as prev
          from cur c left join ops.freshness_state s using (platform, source_type)
         where c.status is distinct from s.last_status),
    ev as (
        insert into ops.freshness_event (platform, source_type, from_status, to_status, last_ok_at)
        select platform, source_type, prev, status, last_ok_at from chg
        returning platform, source_type, from_status, to_status),
    al as (
        insert into ops.cron_alert_log (jobname, level, consecutive_failures, last_failure_message)
        select 'freshness:' || platform || '/' || source_type,
               case when to_status = 'stale' then 'alert' else 'recovered' end, 0,
               format('%s %s is %s (was %s)', platform, source_type, to_status, coalesce(from_status, 'unknown'))
          from ev where to_status = 'stale' or (from_status = 'stale' and to_status = 'fresh')
        returning 1)
    select count(*) into v_ev from ev;

    insert into ops.freshness_state as t (platform, source_type, last_status, status_since)
    select platform, source_type, status, now() from dash.v_data_freshness
    on conflict (platform, source_type) do update set
        last_status  = excluded.last_status,
        status_since = case when t.last_status is distinct from excluded.last_status then now() else t.status_since end;

    return jsonb_build_object('status', 'ok', 'status_changes', v_ev,
                              'stale', (select count(*) from dash.v_data_freshness where status = 'stale'),
                              'fresh', (select count(*) from dash.v_data_freshness where status = 'fresh'));
end $function$
;

CREATE OR REPLACE FUNCTION silver.register_category_scopes()
 RETURNS text[]
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION silver.register_platforms()
 RETURNS text[]
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare v text[];
begin
    with found as (
        select lower(btrim(platform::text)) p from public.shelf_snapshots  where platform is not null
        union select lower(btrim(platform::text)) from public.search_snapshots where platform is not null
        union select lower(btrim(platform::text)) from public.platform_listings where platform is not null
        union select lower(btrim(platform::text)) from public.stores            where platform is not null),
    ins as (
        insert into silver.dim_platform (platform, platform_name, is_test)
        select f.p, initcap(replace(f.p, '_', ' ')), false
        from found f
        where f.p ~ '^[a-z0-9_]+$'
          and not exists (select 1 from silver.dim_platform d where d.platform = f.p)
        returning platform)
    select coalesce(array_agg(platform), '{}') into v from ins;
    return v;
end $function$
;

CREATE OR REPLACE FUNCTION silver.reject_match(p_review_id bigint, p_by text DEFAULT SESSION_USER)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
AS $function$
declare q silver.match_review_queue%rowtype;
begin
    select * into q from silver.match_review_queue where review_id = p_review_id and status = 'pending' for update;
    if not found then raise exception 'review % not found or already decided', p_review_id; end if;
    update silver.match_review_queue set status = 'rejected', decided_by = p_by, decided_at = now() where review_id = p_review_id;
    update silver.product_xref set match_status = 'NEW_MASTER', match_method = 'REVIEW_REJECTED',
           reviewed_by = p_by, reviewed_at = now()
     where product_key = q.product_key and match_status = 'PENDING_REVIEW'
       and not exists (select 1 from silver.match_review_queue q2
                       where q2.product_key = q.product_key and q2.status = 'pending');
end $function$
;

CREATE OR REPLACE FUNCTION silver.resequence_sidnl()
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare n_changed int; n_total int;
begin
    perform pg_advisory_xact_lock(727100);   -- same lock as run_pipeline (re-entrant inside it)
    set constraints all deferred;

    -- retired ids lose their meaning once ids move: point anything still using them at the survivor, then drop them
    update silver.product_xref x set sidnl_id = silver.sidnl_resolve(x.sidnl_id)
     where x.sidnl_id in (select sidnl_id from silver.canonical_product where not is_active);
    update silver.match_review_queue q set suggested_sidnl_id = silver.sidnl_resolve(q.suggested_sidnl_id)
     where q.suggested_sidnl_id in (select sidnl_id from silver.canonical_product where not is_active);

    drop table if exists _si_map;
    create temp table _si_map on commit drop as
    select sidnl_id as old_id,
           row_number() over (order by lower(canonical_name), brand_key, size_value nulls first, pack_count,
                                       substr(sidnl_id, 3)::bigint)::int as new_n
      from silver.canonical_product where is_active;

    select count(*) filter (where old_id <> silver.format_sidnl_id(new_n)), count(*) into n_changed, n_total from _si_map;

    if n_changed = 0 and not exists (select 1 from silver.canonical_product where not is_active) then
        return 0;
    end if;

    delete from silver.canonical_product where not is_active;

    -- phase 1: move to a temporary band (1,000,000+) so no id collides while renumbering
    update silver.canonical_product c set sidnl_id = 'SI' || (1000000 + m.new_n) from _si_map m where c.sidnl_id = m.old_id;
    update silver.product_xref x set sidnl_id = 'SI' || (1000000 + m.new_n) from _si_map m where x.sidnl_id = m.old_id;
    update silver.match_review_queue q set suggested_sidnl_id = 'SI' || (1000000 + m.new_n) from _si_map m where q.suggested_sidnl_id = m.old_id;

    -- phase 2: final ids
    update silver.canonical_product c set sidnl_id = silver.format_sidnl_id(m.new_n) from _si_map m where c.sidnl_id = 'SI' || (1000000 + m.new_n);
    update silver.product_xref x set sidnl_id = silver.format_sidnl_id(m.new_n) from _si_map m where x.sidnl_id = 'SI' || (1000000 + m.new_n);
    update silver.match_review_queue q set suggested_sidnl_id = silver.format_sidnl_id(m.new_n) from _si_map m where q.suggested_sidnl_id = 'SI' || (1000000 + m.new_n);

    perform setval('silver.sidnl_id_seq', greatest(n_total, 1), n_total > 0);
    return n_changed;
end $function$
;

CREATE OR REPLACE FUNCTION silver.retry_dead_letters(p_force boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare
    r record; v_run bigint; v_ok int := 0; v_fail int := 0; v_st text; v_er text;
    v_max int := coalesce(silver.cfg('dead_letter_max_retries'), 24)::int;
    v_min int := coalesce(silver.cfg('dead_letter_retry_minutes'), 60)::int;
begin
    if not exists (select 1 from ops.dead_letter where status = 'open') then
        return jsonb_build_object('status', 'nothing to do');
    end if;
    if not pg_try_advisory_xact_lock(727100) then
        return jsonb_build_object('status', 'skipped', 'reason', 'pipeline run in progress');
    end if;
    insert into ops.etl_run (brand_key) values ('(dead-letter retry)') returning run_id into v_run;

    for r in select * from ops.dead_letter
              where status = 'open' and source_table = 'public.shelf_positions'
                and (p_force or (next_retry_at <= now() and retry_count < v_max))
              order by dl_id limit 500
    loop
        begin
            update ops.dead_letter set status = 'retrying' where dl_id = r.dl_id;
            perform silver.load_category_chunk(r.platform, r.l1_id, r.l2_id, r.bronze_id - 1, r.bronze_id, v_run);
            if not exists (select 1 from silver.fact_shelf_position where source_record_id = r.bronze_id) then
                raise exception using errcode = '22S02', message = 'row not loaded (scope disabled or snapshot not ok)';
            end if;
            update ops.dead_letter set status = 'resolved', resolved_at = now(), resolved_by = 'auto-retry', last_tried_at = now()
             where dl_id = r.dl_id;
            v_ok := v_ok + 1;
        exception when others then
            v_st := sqlstate; v_er := sqlerrm;
            update ops.dead_letter
               set retry_count = retry_count + 1, last_tried_at = now(), reason = left(v_er, 1000), sqlstate = v_st,
                   next_retry_at = now() + least(make_interval(mins => v_min * power(2, least(retry_count, 10))::int), interval '24 hours')
             where dl_id = r.dl_id;
            v_fail := v_fail + 1;
        end;
    end loop;

    insert into ops.cron_alert_log (jobname, level, consecutive_failures, last_failure_message)
    select 'dead-letter:' || coalesce(platform, '?') || '/' || coalesce(l1_id, '?') || '/' || coalesce(l2_id, '?'), 'alert', max(retry_count),
           format('%s bronze rows stopped auto-retrying after %s attempts; latest error: %s', count(*), v_max,
                  (array_agg(reason order by last_tried_at desc))[1])
      from ops.dead_letter
     where status = 'open' and retry_count = v_max and last_tried_at > now() - interval '30 minutes'
     group by platform, l1_id, l2_id;

    update ops.etl_run set finished_at = now(), status = 'success',
           stats = jsonb_build_object('resolved', v_ok, 'still_failing', v_fail) where run_id = v_run;
    if v_ok > 0 then
        update ops.pipeline_run set gold_status = 'pending'
         where run_id = (select max(run_id) from ops.pipeline_run where status = 'success') and gold_status is distinct from 'pending';
    end if;
    return jsonb_build_object('status', 'ok', 'resolved', v_ok, 'still_failing', v_fail);
end $function$
;

CREATE OR REPLACE FUNCTION silver.run_gold_pending()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
 SET statement_timeout TO '600s'
AS $function$
declare
    v record; v_t timestamptz; v_att int; v_state text; v_msg text; v_class text; v_next timestamptz; v_secs numeric;
    v_max int := coalesce(silver.cfg('gold_max_attempts'), 5)::int;
    v_vis_days int := silver.cfg('gold_visibility_days')::int;
    v_tables text[] := array['dim_platform', 'dim_city', 'dim_brand', 'dim_category', 'dim_product', 'dim_store', 'dim_sidnl',
                             'pricing', 'availability', 'visibility'];
begin
    if not pg_try_advisory_xact_lock(727101) then
        return jsonb_build_object('status', 'skipped', 'reason', 'dash refresh in progress');
    end if;
    select run_id, gold_status, gold_attempts into v from ops.pipeline_run
     where status = 'success' and (gold_status = 'pending' or (gold_status = 'failed' and gold_next_at <= now()))
     order by run_id desc limit 1;
    if not found then return jsonb_build_object('status', 'idle'); end if;
    update ops.pipeline_run set gold_status = 'superseded'
     where status = 'success' and gold_status = 'pending' and run_id < v.run_id;

    v_t := clock_timestamp();
    begin
        perform dash.sync_dims();
        perform dash.refresh(v_vis_days);
    exception
        when query_canceled then
            v_state := sqlstate; v_msg := 'timeout: ' || sqlerrm;
        when others then
            v_state := sqlstate; v_msg := sqlerrm;
    end;
    v_secs := round(extract(epoch from clock_timestamp() - v_t)::numeric, 2);

    if v_state is not null then
        v_att   := coalesce(v.gold_attempts, 0) + 1;
        v_class := silver.classify_error(v_state);
        v_next  := case when v_class = 'transient' and v_att < v_max
                        then now() + make_interval(mins => silver.backoff_minutes(v_att)) end;
        update ops.pipeline_run
           set gold_status = 'failed', gold_error = left(v_msg, 1000), gold_attempts = v_att,
               gold_seconds = v_secs, gold_next_at = v_next
         where run_id = v.run_id;
        insert into dash.refresh_state (key, value) values ('last_error', left(v_msg, 1000))
        on conflict (key) do update set value = excluded.value, updated_at = now();
        insert into dash.refresh_table_state (table_name, last_attempt_at, last_attempt_run_id, last_status, last_error, gold_attempts, next_retry_at)
        select t, now(), v.run_id, 'failed', left(v_msg, 1000), v_att, v_next from unnest(v_tables) t
        on conflict (table_name) do update
           set last_attempt_at = excluded.last_attempt_at, last_attempt_run_id = excluded.last_attempt_run_id,
               last_status = 'failed', last_error = excluded.last_error,
               gold_attempts = excluded.gold_attempts, next_retry_at = excluded.next_retry_at;
        return jsonb_build_object('status', 'failed', 'run_id', v.run_id, 'error', v_msg, 'sqlstate', v_state,
                                  'error_class', v_class, 'attempt', v_att, 'next_attempt_at', v_next);
    end if;

    delete from dash.refresh_state where key = 'last_error';
    update ops.pipeline_run set gold_status = 'success', gold_error = null, gold_next_at = null, gold_seconds = v_secs
     where run_id = v.run_id;
    insert into dash.refresh_table_state (table_name, last_refreshed_at, last_run_id, row_count, last_attempt_at,
                                          last_attempt_run_id, last_status, last_error, gold_attempts, next_retry_at)
    select c.t, now(), v.run_id, c.n, now(), v.run_id, 'success', null, 0, null
      from (values ('dim_platform', (select count(*) from dash.dim_platform)),
                   ('dim_city',     (select count(*) from dash.dim_city)),
                   ('dim_brand',    (select count(*) from dash.dim_brand)),
                   ('dim_category', (select count(*) from dash.dim_category)),
                   ('dim_product',  (select count(*) from dash.dim_product)),
                   ('dim_store',    (select count(*) from dash.dim_store)),
                   ('dim_sidnl',    (select count(*) from dash.dim_sidnl)),
                   ('pricing',      (select count(*) from dash.pricing)),
                   ('availability', (select count(*) from dash.availability)),
                   ('visibility',   (select count(*) from dash.visibility))) c(t, n)
    on conflict (table_name) do update
       set last_refreshed_at = excluded.last_refreshed_at, last_run_id = excluded.last_run_id, row_count = excluded.row_count,
           last_attempt_at = excluded.last_attempt_at, last_attempt_run_id = excluded.last_attempt_run_id,
           last_status = 'success', last_error = null, gold_attempts = 0, next_retry_at = null;
    return jsonb_build_object('status', 'success', 'run_id', v.run_id, 'dash', 'success', 'visibility_days', v_vis_days);
end $function$
;

CREATE OR REPLACE FUNCTION silver.run_maintenance()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare
    v_keep int := greatest(coalesce(silver.cfg('cron_history_keep_days'), 14)::int, 8);
    v_purged bigint; r record; v_analyzed text[] := '{}';
begin
    delete from cron.job_run_details where coalesce(end_time, start_time) < now() - make_interval(days => v_keep);
    get diagnostics v_purged = row_count;

    for r in select s.schemaname, s.relname from pg_stat_user_tables s
              where s.schemaname in ('silver', 'dash')
                and s.last_analyze is null and s.last_autoanalyze is null
                and pg_relation_size(s.relid) > 0
    loop
        execute format('analyze %I.%I', r.schemaname, r.relname);
        v_analyzed := v_analyzed || (r.schemaname || '.' || r.relname);
    end loop;

    return jsonb_build_object('cron_history_purged', v_purged, 'keep_days', v_keep, 'analyzed', to_jsonb(v_analyzed));
end $function$
;

CREATE OR REPLACE FUNCTION silver.run_pipeline(p_force boolean DEFAULT false, p_trigger text DEFAULT 'manual'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
 SET statement_timeout TO '600s'
AS $function$
declare
    s record; b record; v_max bigint;
    v_new jsonb := '{}'::jsonb; v_maxes jsonb := '{}'::jsonb; v_steps jsonb := '{}'::jsonb;
    v_unmapped int; v_run bigint; v_t timestamptz;
    v_min int := coalesce(silver.cfg('pipeline_min_interval_seconds'), 120)::int;
    v_tmp jsonb; v_cat jsonb; v_plat text[]; v_brands text[]; v_cats text[]; v_full boolean;
    v_f_disc boolean := false; v_f_brand boolean := false; v_f_shelf boolean := false; v_f_canon boolean := false;
    v_gate jsonb; v_blk_shelf boolean := false; v_blk_canon boolean := false; v_blocked text[] := '{}';
    v_status text; v_adv jsonb := '[]'::jsonb; v_n int; v_last record;
    v_stage text; v_msg text;
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
    if not p_force then
        select status, new_data into v_last from ops.pipeline_run order by run_id desc limit 1;
        if v_last.status = 'blocked' and v_last.new_data = v_new and v_unmapped = 0 then
            return jsonb_build_object('status', 'idle_blocked', 'reason', 'last run was blocked by the quality gate and nothing changed');
        end if;
        if exists (select 1 from ops.pipeline_run where started_at > now() - make_interval(secs => v_min)) then
            return jsonb_build_object('status', 'debounced', 'new_data', v_new);
        end if;
    end if;

    insert into ops.pipeline_run (trigger, new_data) values (p_trigger, v_new) returning run_id into v_run;

    begin
        v_plat := silver.register_platforms();
        v_cats := silver.register_category_scopes();
        perform silver.refresh_brand_strings(p_force);
        v_brands := silver.onboard_brands();
        v_steps := v_steps || jsonb_build_object('discover', jsonb_build_object(
            'ok', true, 'new_platforms', to_jsonb(v_plat), 'new_categories', to_jsonb(v_cats), 'new_brands', to_jsonb(v_brands)));
    exception when others then
        v_f_disc := true; v_plat := '{}';
        v_steps := v_steps || jsonb_build_object('discover', jsonb_build_object('ok', false, 'error', sqlerrm, 'sqlstate', sqlstate));
    end;
    v_full := p_force or coalesce(array_length(v_plat, 1), 0) > 0;

    for b in select brand_key from silver.brand_scope where is_enabled order by brand_key loop
        v_t := clock_timestamp();
        begin
            v_tmp := silver.refresh_brand(b.brand_key, v_full);
            v_steps := v_steps || jsonb_build_object('refresh_brand:' || b.brand_key, jsonb_build_object(
                'ok', true, 'seconds', round(extract(epoch from clock_timestamp() - v_t)::numeric, 2), 'stats', v_tmp));
        exception when others then
            v_f_brand := true;
            v_steps := v_steps || jsonb_build_object('refresh_brand:' || b.brand_key, jsonb_build_object('ok', false, 'error', sqlerrm, 'sqlstate', sqlstate));
        end;
    end loop;

    v_t := clock_timestamp();
    begin
        v_cat := silver.refresh_category_market(v_full);
        v_f_shelf := jsonb_array_length(v_cat -> 'failed_scopes') > 0;
        v_steps := v_steps || jsonb_build_object('refresh_category_market', jsonb_build_object(
            'ok', not v_f_shelf, 'seconds', round(extract(epoch from clock_timestamp() - v_t)::numeric, 2),
            'failed_scopes', v_cat -> 'failed_scopes',
            'error', (select value ->> 'error' from jsonb_each(v_cat -> 'scopes') where value ->> 'ok' = 'false' limit 1),
            'sqlstate', (select value ->> 'sqlstate' from jsonb_each(v_cat -> 'scopes') where value ->> 'ok' = 'false' limit 1),
            'stats', v_cat - 'scopes'));
    exception when others then
        v_f_shelf := true; v_cat := null;
        v_steps := v_steps || jsonb_build_object('refresh_category_market', jsonb_build_object('ok', false, 'error', sqlerrm, 'sqlstate', sqlstate));
    end;

    begin
        v_steps := v_steps || jsonb_build_object('map_new_products', jsonb_build_object('ok', true, 'result', silver.map_new_products()));
        v_steps := v_steps || jsonb_build_object('sync_canonical_attrs', jsonb_build_object('ok', true, 'updated', silver.sync_canonical_attrs()));
        v_steps := v_steps || jsonb_build_object('resequence_sidnl', jsonb_build_object('ok', true, 'renumbered', silver.resequence_sidnl()));
    exception when others then
        v_f_canon := true;
        v_steps := v_steps || jsonb_build_object('canonical_map', jsonb_build_object('ok', false, 'error', sqlerrm, 'sqlstate', sqlstate));
    end;

    begin
        v_gate := silver.dq_run_gate(v_run, nullif(v_maxes ->> 'public.shelf_positions', '')::bigint);
        v_blk_canon := coalesce((v_gate ->> 'canonical_blocking')::int, 0) > 0;
        v_blk_shelf := coalesce((v_gate ->> 'shelf_blocking')::int, 0) > 0;
        select coalesce(array_agg(distinct d.scope), '{}') into v_blocked
          from ops.dq_result d where d.run_id = v_run and d.blocks and d.scope like '%/%/%';
        v_steps := v_steps || jsonb_build_object('quality_gate', jsonb_build_object(
            'ok', not (v_blk_canon or v_blk_shelf), 'summary', v_gate));
    exception when others then
        v_f_canon := true;
        v_steps := v_steps || jsonb_build_object('quality_gate', jsonb_build_object('ok', false, 'error', sqlerrm, 'sqlstate', sqlstate));
    end;

    v_status := case when v_f_disc or v_f_brand or v_f_shelf or v_f_canon then 'partial'
                     when v_blk_shelf or v_blk_canon then 'blocked'
                     else 'success' end;

    if v_cat is not null and not (v_f_disc or v_f_canon or v_blk_canon) then
        update silver.category_scope cs
           set last_loaded_id = (v_cat -> 'scopes' -> (cs.platform || '/' || cs.l1_id || '/' || cs.l2_id) ->> 'max_id')::bigint,
               last_loaded_at = now(), last_status = 'ok', last_error = null, consecutive_failures = 0
         where cs.is_enabled
           and (v_cat -> 'scopes' -> (cs.platform || '/' || cs.l1_id || '/' || cs.l2_id) ->> 'ok') = 'true'
           and (v_cat -> 'scopes' -> (cs.platform || '/' || cs.l1_id || '/' || cs.l2_id) ->> 'max_id') is not null
           and not ((cs.platform || '/' || cs.l1_id || '/' || cs.l2_id) = any (v_blocked));
        get diagnostics v_n = row_count;
        v_adv := v_adv || to_jsonb('category scopes advanced: ' || v_n);
    end if;
    update silver.category_scope cs set last_status = 'blocked'
     where (cs.platform || '/' || cs.l1_id || '/' || cs.l2_id) = any (v_blocked);

    if not (v_f_disc or v_f_shelf or v_f_canon or v_blk_shelf or v_blk_canon) then
        update silver.pipeline_source ps
           set last_seen_id = (v_maxes ->> (ps.source_schema || '.' || ps.source_table))::bigint
         where ps.source_table in ('shelf_positions', 'shelf_snapshots') and v_maxes ? (ps.source_schema || '.' || ps.source_table);
        get diagnostics v_n = row_count;
        v_adv := v_adv || to_jsonb('shelf sources advanced: ' || v_n);
    end if;
    if not (v_f_disc or v_f_brand or v_f_canon or v_blk_canon) then
        update silver.pipeline_source ps
           set last_seen_id = (v_maxes ->> (ps.source_schema || '.' || ps.source_table))::bigint
         where ps.source_table not in ('shelf_positions', 'shelf_snapshots') and v_maxes ? (ps.source_schema || '.' || ps.source_table);
        get diagnostics v_n = row_count;
        v_adv := v_adv || to_jsonb('other sources advanced: ' || v_n);
    end if;

    select e.key, e.value ->> 'error' into v_stage, v_msg
      from jsonb_each(v_steps) e where e.value ->> 'ok' = 'false' and e.value ? 'error' order by e.key limit 1;

    update ops.pipeline_run
       set finished_at = clock_timestamp(), status = v_status, steps = v_steps, dq = v_gate, watermarks_advanced = v_adv,
           gold_status = case when v_status = 'success' then 'pending' else 'skipped' end,
           shelf_rows_inserted = coalesce((v_cat -> 'fact_shelf_position' ->> 'inserted')::bigint, 0),
           shelf_rows_updated  = coalesce((v_cat -> 'fact_shelf_position' ->> 'updated')::bigint, 0),
           rows_rejected = coalesce((v_gate ->> 'rejected_rows')::bigint, 0),
           failed_stage = v_stage, error_message = v_msg
     where run_id = v_run;

    return jsonb_build_object('status', v_status, 'run_id', v_run, 'mode', case when v_full then 'full' else 'incremental' end,
                              'new_data', v_new, 'watermarks_advanced', v_adv, 'quality_gate', v_gate,
                              'gold_status', case when v_status = 'success' then 'pending' else 'skipped' end, 'steps', v_steps);
end $function$
;

CREATE OR REPLACE FUNCTION silver.run_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
 SET statement_timeout TO '600s'
AS $function$
declare j ops.pipeline_job%rowtype; r jsonb; v_err text; v_state text; v_res text; v_id bigint; v_found boolean;
begin
    perform silver.enqueue_daily('catchup', true);
    begin perform silver.record_storage_snapshot(); exception when others then null; end;

    select * into j from ops.pipeline_job
     where status in ('queued', 'retry_wait') and coalesce(next_attempt_at, requested_at) <= now()
     order by (job_type = 'daily') desc, job_id limit 1 for update skip locked;
    v_found := found;

    if v_found then
        begin
            r := silver.run_pipeline(j.force, case when j.attempt = 0 then coalesce(j.trigger, 'job') else 'retry-' || (j.attempt + 1) end);
        exception when others then
            v_err := sqlerrm; v_state := sqlstate; r := null;
        end;
        v_id := j.job_id;
    else
        begin
            r := silver.run_pipeline(false, 'cron');
        exception when others then
            v_err := sqlerrm; v_state := sqlstate; r := null;
        end;
        if v_err is null and r ->> 'status' in ('idle', 'idle_blocked', 'debounced', 'skipped') then
            return r;
        end if;
        insert into ops.pipeline_job (job_type, trigger, force, status) values ('regular', 'cron', false, 'queued')
        returning job_id into v_id;
    end if;

    v_res := silver.pipeline_job_apply(v_id, r, v_err, v_state);
    if r ->> 'run_id' is not null then
        update ops.pipeline_run set job_id = v_id, attempt = (select attempt from ops.pipeline_job where job_id = v_id)
         where run_id = (r ->> 'run_id')::bigint;
    end if;
    return jsonb_build_object('job_id', v_id, 'job_status', v_res, 'run_status', r ->> 'status', 'error', v_err);
end $function$
;

CREATE OR REPLACE FUNCTION silver.score_pair(a silver.match_feat, b silver.match_feat)
 RETURNS silver.score_t
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
AS $function$
declare
    w_name numeric := silver.cfg('w_name');      w_brand numeric := silver.cfg('w_brand');
    w_size numeric := silver.cfg('w_size');      w_var   numeric := silver.cfg('w_variant');
    w_cat  numeric := silver.cfg('w_category');  tol     numeric := silver.cfg('size_tol');
    bmin   numeric := silver.cfg('brand_min_sim'); vmin  numeric := silver.cfg('variant_min_sim');
    pa int := coalesce(a.pack_count, 1);         pb int := coalesce(b.pack_count, 1);
    name_sim numeric; brand_sim numeric := 1; size_sim numeric := 1; var_sim numeric := 1; cat_sim numeric := 1;
    has_brand boolean; has_size boolean; has_var boolean; has_cat boolean;
    size_diff numeric; sum_w numeric; total numeric;
    ok boolean := true; reason text := 'PASSED';
begin
    name_sim := silver.token_set_sim(a.name_clean, b.name_clean);

    has_brand := coalesce(a.brand, '') <> '' or coalesce(b.brand, '') <> '';
    if not has_brand then brand_sim := 1;
    elsif replace(coalesce(a.brand, ''), ' ', '') = replace(coalesce(b.brand, ''), ' ', '') then brand_sim := 1;
    elsif coalesce(a.brand, '') = '' or coalesce(b.brand, '') = '' then brand_sim := 0.5;
    else
        brand_sim := silver.token_set_sim(a.brand, b.brand);
        if brand_sim < bmin then brand_sim := 0; end if;
    end if;

    has_size := a.size_value is not null or b.size_value is not null;
    if pa <> pb then size_sim := 0;
    elsif not has_size then size_sim := 1;
    elsif a.size_value is null or b.size_value is null then size_sim := 0.5;
    elsif a.size_unit is distinct from b.size_unit then size_sim := 0;
    else
        size_diff := abs(a.size_value - b.size_value) / greatest(a.size_value, b.size_value, 0.001);
        size_sim := case when size_diff <= 0.01 then 1 when size_diff <= tol then 0.8 else 0 end;
    end if;

    has_var := coalesce(a.variant_key, '') <> '' or coalesce(b.variant_key, '') <> '';
    if not has_var then var_sim := 1;
    elsif a.variant_key = b.variant_key then var_sim := 1;
    elsif coalesce(a.variant_key, '') = '' or coalesce(b.variant_key, '') = '' then var_sim := 0.5;
    else var_sim := silver.token_set_sim(a.variant_key, b.variant_key);
    end if;

    has_cat := a.cat_l1 is not null or b.cat_l1 is not null;
    if not has_cat then cat_sim := 1;
    elsif a.cat_l1 is null or b.cat_l1 is null then cat_sim := 0.5;
    elsif a.cat_l1 = b.cat_l1 then
        cat_sim := case when a.cat_l2 is not distinct from b.cat_l2
                        then case when a.cat_l3 is not distinct from b.cat_l3 then 1 else 0.9 end
                        else 0.75 end;
    elsif (a.cat_l3 is not null and a.cat_l3 = b.cat_l3) or (a.cat_l2 is not null and a.cat_l2 = b.cat_l2) then cat_sim := 0.85;
    else cat_sim := 0;
    end if;

    sum_w := w_name + case when has_brand then w_brand else 0 end + case when has_size then w_size else 0 end
                    + case when has_var then w_var else 0 end + case when has_cat then w_cat else 0 end;
    total := (w_name * name_sim
              + case when has_brand then w_brand * brand_sim else 0 end
              + case when has_size  then w_size  * size_sim  else 0 end
              + case when has_var   then w_var   * var_sim   else 0 end
              + case when has_cat   then w_cat   * cat_sim   else 0 end) / nullif(sum_w, 0);

    if pa <> pb then ok := false; reason := 'PACK_COUNT_MISMATCH';
    elsif a.size_value is not null and b.size_value is not null
          and (a.size_unit is distinct from b.size_unit
               or abs(a.size_value - b.size_value) / greatest(a.size_value, b.size_value, 0.001) > tol)
        then ok := false; reason := 'SIZE_MISMATCH';
    elsif coalesce(a.brand, '') <> '' and coalesce(b.brand, '') <> '' and brand_sim < bmin
        then ok := false; reason := 'BRAND_CONFLICT';
    elsif coalesce(a.variant_key, '') <> '' and coalesce(b.variant_key, '') <> ''
          and a.variant_key <> b.variant_key and var_sim < vmin
        then ok := false; reason := 'VARIANT_CONFLICT';
    end if;

    return (round(coalesce(total, 0), 4), round(name_sim, 4), round(brand_sim, 4), round(size_sim, 4),
            round(var_sim, 4), round(cat_sim, 4), ok, reason)::silver.score_t;
end $function$
;

CREATE OR REPLACE FUNCTION silver.selftest_matcher()
 RETURNS TABLE(test text, ok boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
AS $function$
declare a silver.match_feat; b silver.match_feat; s silver.score_t; ka int; kx int; ky int;
begin
    -- Uses only rows that already exist in silver.dim_product; nothing is inserted.
    select product_key into ka from silver.dim_product where size_value is not null order by product_key limit 1;
    if ka is null then
        test := 'real-product tests'; ok := true; detail := 'skipped: silver.dim_product has no products with a size yet'; return next;
    else
        a := silver.features_of(ka);
        s := silver.score_pair(a, a);
        test := 'a real product matches itself'; ok := s.score = 1 and s.rule_ok; detail := s::text; return next;

        b := a; b.size_value := a.size_value * 2;
        s := silver.score_pair(a, b);
        test := 'same product at double the size is never the same product'; ok := not s.rule_ok and s.rule_reason = 'SIZE_MISMATCH'; detail := s::text; return next;

        b := a; b.pack_count := coalesce(a.pack_count, 1) + 1;
        s := silver.score_pair(a, b);
        test := 'different pack count is never the same product'; ok := not s.rule_ok and s.rule_reason = 'PACK_COUNT_MISMATCH'; detail := s::text; return next;
    end if;

    select x.product_key, y.product_key into kx, ky
    from silver.dim_product x
    join silver.dim_product y on y.brand_key = x.brand_key and y.size_value = x.size_value
                              and y.size_unit = x.size_unit and y.pack_count = x.pack_count
                              and y.product_key > x.product_key
                              and (silver.features_of(y.product_key)).variant_key is distinct from (silver.features_of(x.product_key)).variant_key
    order by x.product_key, y.product_key limit 1;
    if kx is null then
        test := 'two different real SKUs of equal size must not auto-merge'; ok := true; detail := 'skipped: no such pair in silver.dim_product'; return next;
    else
        s := silver.score_pair(silver.features_of(kx), silver.features_of(ky));
        test := 'two different real SKUs of equal size must not auto-merge (product_key ' || kx || ' vs ' || ky || ')';
        ok := not (s.score >= silver.cfg('th_auto') and s.rule_ok); detail := s::text; return next;
    end if;

    return query select * from silver.selftest_matcher_pure();
end $function$
;

CREATE OR REPLACE FUNCTION silver.selftest_matcher_pure()
 RETURNS TABLE(test text, ok boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
AS $function$
begin
    test := 'token_set_sim: subset of tokens = 1'; ok := silver.token_set_sim('alpha beta', 'alpha gamma beta') = 1; detail := ''; return next;
    test := 'token_set_sim: unrelated tokens < 0.3'; ok := silver.token_set_sim('alpha beta', 'gamma delta') < 0.3; detail := silver.token_set_sim('alpha beta', 'gamma delta')::text; return next;
    test := 'synonym table: every active synonym rewrites to its canonical token';
    ok := not exists (select 1 from silver.ref_variant_synonym r
                      where r.is_active and silver.canon_tokens(r.syn_key) is distinct from silver.canon_tokens(r.variant));
    detail := ''; return next;
    test := 'SI id format 1/999/1000'; ok := silver.format_sidnl_id(1) = 'SI001' and silver.format_sidnl_id(999) = 'SI999' and silver.format_sidnl_id(1000) = 'SI1000'; detail := ''; return next;
    test := 'SI id normalise'; ok := silver.sidnl_normalize(' si1 ') = 'SI001' and silver.sidnl_normalize('SI0001') = 'SI001' and silver.sidnl_normalize('SI000') is null and silver.sidnl_normalize('xyz') is null; detail := ''; return next;
end $function$
;

CREATE OR REPLACE FUNCTION silver.selftest_parser()
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare
    p silver.pack_t;
begin
    assert silver.norm_key('Mr. Munchies')   = 'mr munchies',  'norm_key dotted';
    assert silver.norm_key('MR.MUNCHIES')    = 'mr munchies',  'norm_key upper';
    assert silver.norm_key('Mr.Munchies')    = 'mr munchies',  'norm_key no space';
    assert silver.norm_key('Lay''s')         = 'lays',         'norm_key apostrophe';
    assert silver.norm_key('Crunch & Munch') = 'crunch and munch', 'norm_key ampersand';
    assert silver.norm_key('   ')            is null,          'norm_key blank';
    assert silver.norm_key(null)             is null,          'norm_key null';

    assert silver.brand_matches('mr munchies', 'Mr. Munchies'),     'brand exact';
    assert silver.brand_matches('mr munchies', 'MrMunchies'),       'brand compact';
    assert silver.brand_matches('mr munchies', 'mr-munchies'),      'brand hyphen';
    assert not silver.brand_matches('mr munchies', 'Crunch & Munch'), 'brand must not substring-match';
    assert not silver.brand_matches('mr munchies', 'Nestle Munch'),   'brand must not substring-match 2';
    assert not silver.brand_matches('mr munchies', null),             'brand null';

    p := silver.parse_pack('270 g');
    assert (p.size_value, p.size_unit, p.pack_count) = (270, 'g', 1), 'pack 270 g';
    p := silver.parse_pack('1 pc (38.5 g)');
    assert (p.size_value, p.size_unit, p.pack_count) = (38.5, 'g', 1), 'pack 1 pc (38.5 g)';
    p := silver.parse_pack('330 ml');
    assert (p.size_value, p.size_unit, p.pack_count) = (330, 'ml', 1), 'pack 330 ml';
    p := silver.parse_pack('1 L');
    assert (p.size_value, p.size_unit, p.pack_count) = (1000, 'ml', 1), 'pack 1 L -> 1000 ml';
    p := silver.parse_pack('1.5 Ltr');
    assert (p.size_value, p.size_unit, p.pack_count) = (1500, 'ml', 1), 'pack 1.5 Ltr';
    p := silver.parse_pack('2 kg');
    assert (p.size_value, p.size_unit, p.pack_count) = (2000, 'g', 1), 'pack 2 kg';
    p := silver.parse_pack('6 x 330 ml');
    assert (p.size_value, p.size_unit, p.pack_count) = (330, 'ml', 6), 'pack 6 x 330 ml';
    p := silver.parse_pack('0,5 kg');
    assert (p.size_value, p.size_unit, p.pack_count) = (500, 'g', 1), 'pack decimal comma';
    p := silver.parse_pack('1 N');
    assert (p.size_value, p.size_unit, p.pack_count) = (1, 'pc', 1), 'pack 1 N';
    p := silver.parse_pack('3 pcs');
    assert (p.size_value, p.size_unit, p.pack_count) = (3, 'pc', 1), 'pack 3 pcs = one pack of 3 pieces';
    p := silver.parse_pack(null);
    assert p.size_value is null and p.pack_count = 1, 'pack null';
    p := silver.parse_pack('assorted');
    assert p.size_value is null or p.size_unit = 'pc', 'pack junk does not crash';

    -- silver_056: exact pack strings seen in bronze public.platform_products
    p := silver.parse_pack('100 g X 2');
    assert (p.size_value, p.size_unit, p.pack_count) = (100, 'g', 2), 'pack 100 g X 2';
    p := silver.parse_pack('500 ml X 4');
    assert (p.size_value, p.size_unit, p.pack_count) = (500, 'ml', 4), 'pack 500 ml X 4';
    p := silver.parse_pack('2 x 1 pc');
    assert (p.size_value, p.size_unit, p.pack_count) = (1, 'pc', 2), 'pack 2 x 1 pc';
    p := silver.parse_pack('2 x 10 pcs');
    assert (p.size_value, p.size_unit, p.pack_count) = (10, 'pc', 2), 'pack 2 x 10 pcs';
    p := silver.parse_pack('10 pcs');
    assert (p.size_value, p.size_unit, p.pack_count) = (10, 'pc', 1), 'pack 10 pcs';
    p := silver.parse_pack('30 tabs');
    assert (p.size_value, p.size_unit, p.pack_count) = (30, 'pc', 1), 'pack 30 tabs';
    p := silver.parse_pack('60 capsules');
    assert (p.size_value, p.size_unit, p.pack_count) = (60, 'pc', 1), 'pack 60 capsules';
    p := silver.parse_pack('4 packs');
    assert (p.size_value, p.size_unit, p.pack_count) = (4, 'pc', 1), 'pack 4 packs';
    p := silver.parse_pack('1 unit + 1 unit');
    assert (p.size_value, p.size_unit, p.pack_count) = (1, 'pc', 2), 'pack 1 unit + 1 unit';
    p := silver.parse_pack('40U x 25g');
    assert (p.size_value, p.size_unit, p.pack_count) = (25, 'g', 40), 'pack 40U x 25g';
    p := silver.parse_pack('7 pcs + 102 g');
    assert (p.size_value, p.size_unit, p.pack_count) = (102, 'g', 1), 'pack 7 pcs + 102 g does not multiply';
    p := silver.parse_pack('1 pack (1.25 kg)');
    assert (p.size_value, p.size_unit, p.pack_count) = (1250, 'g', 1), 'pack 1 pack (1.25 kg)';
    p := silver.parse_pack('1 pack (5 X 10 ml)');
    assert (p.size_value, p.size_unit, p.pack_count) = (10, 'ml', 5), 'pack 1 pack (5 X 10 ml)';
    p := silver.parse_pack('2 x 45 g + 35 g');
    assert (p.size_value, p.size_unit, p.pack_count) = (125, 'g', 1), 'pack 2 x 45 g + 35 g';
    p := silver.parse_pack('100 g + 100 g');
    assert (p.size_value, p.size_unit, p.pack_count) = (100, 'g', 2), 'pack 100 g + 100 g';

    assert silver.parse_variant('Mr. Munchies Cheese Chilli Samosa (Frozen)', 'Mr. Munchies', 'Samosa') = 'Cheese Chilli', 'variant samosa';
    assert silver.parse_variant('Mr. Munchies Veg Spring Roll (Frozen)',      'Mr. Munchies', 'Spring Roll') = 'Veg', 'variant roll';
    assert silver.parse_variant('Mr. Munchies Spicy Frozen Paneer Bites',     'Mr. Munchies', 'Frozen Paneer Bites') = 'Spicy', 'variant paneer';
    assert silver.parse_variant('Mr. Munchies Lasooni Soya Chaap',            'Mr. Munchies', 'Soya Chaap') = 'Lasooni', 'variant chaap';
    assert silver.parse_variant('Mr. Munchies Samosa',                        'Mr. Munchies', 'Samosa') is null, 'variant empty -> null';

    assert silver.map_stock_status('in_stock')     = 'in_stock',     'state in';
    assert silver.map_stock_status('OUT_OF_STOCK') = 'out_of_stock', 'state out';
    assert silver.map_stock_status('not_listed')   = 'not_listed',   'state nl';
    assert silver.map_stock_status('weird')        = 'unknown',      'state unknown';
    assert silver.map_stock_status(null)           = 'unknown',      'state null';

    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',3,179,179)) = 'valid',   'dq clean';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'out_of_stock',0,null,null)) = 'valid', 'dq oos without price is valid';
    assert silver.dq_status(silver.reading_dq(true,false,now(),'in_stock',3,179,179)) = 'invalid', 'dq no store';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',-1,179,179)) = 'invalid', 'dq negative inv';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',3,200,179)) = 'suspect', 'dq sp > mrp';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',3,179,null)) = 'suspect', 'dq mrp missing';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'out_of_stock',4,179,179)) = 'suspect', 'dq oos with inventory';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',3,null,null)) = 'suspect', 'dq in stock no price';
    assert silver.dq_status(silver.reading_dq(true,true,now() + interval '30 days','in_stock',3,179,179)) = 'invalid', 'dq future ts';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'unknown',3,179,179)) = 'invalid', 'dq unknown state';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'not_listed',null,null,null)) = 'valid', 'dq not_listed valid';
    return 'all parser tests passed';
end
$function$
;

CREATE OR REPLACE FUNCTION silver.send_test_alert()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$ begin
    insert into ops.alert_outbox (dedupe_key, source, severity, title, body)
    values ('test:' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS'), 'heartbeat', 'info', 'Test alert',
            'Sent by silver.send_test_alert(). If you can read this, alert delivery works.');
    return 'queued; it is sent within a minute if alert_delivery_enabled = 1 and the Vault secret slack_webhook_url exists';
end $function$
;

CREATE OR REPLACE FUNCTION silver.sidnl_everything(p_id text, p_row_limit integer DEFAULT 1000)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION silver.sidnl_find(p_query text, p_limit integer DEFAULT 10)
 RETURNS TABLE(sidnl_id text, canonical_name text, platform_ids jsonb, match_type text, similarity numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION silver.sidnl_normalize(p_id text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
    select case
             when upper(btrim(coalesce(p_id, ''))) ~ '^SI0*[1-9][0-9]*$'
             then silver.format_sidnl_id(regexp_replace(upper(btrim(p_id)), '^SI0*', '')::bigint)
           end
$function$
;

CREATE OR REPLACE FUNCTION silver.sidnl_resolve(p_id text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
    with recursive r(id, depth) as (
        select c.sidnl_id, 0 from silver.canonical_product c where c.sidnl_id = silver.sidnl_normalize(p_id)
        union all
        select c.merged_into, r.depth + 1
        from r join silver.canonical_product c on c.sidnl_id = r.id
        where c.merged_into is not null and r.depth < 10)
    select id from r order by depth desc limit 1
$function$
;

CREATE OR REPLACE FUNCTION silver.slack_text(p_severity text, p_title text, p_body text, p_source text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$ select replace(replace(replace(
        format('*[SIDNL %s]* %s', p_severity, p_title) || case when coalesce(p_body, '') <> '' then E'\n' || p_body else '' end
        || E'\n(source: ' || p_source || ')', '&', '&amp;'), '<', '&lt;'), '>', '&gt;') $function$
;

CREATE OR REPLACE FUNCTION silver.storage_usage()
 RETURNS TABLE(db_bytes bigint, wal_bytes bigint, used_bytes bigint, plan_bytes bigint, used_pct numeric, level text)
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
declare v_db bigint := pg_database_size(current_database()); v_wal bigint := 0; v_plan bigint;
        v_w numeric := coalesce(silver.cfg('storage_warn_pct'),70); v_c numeric := coalesce(silver.cfg('storage_crit_pct'),85);
begin
  begin select coalesce(sum(size),0) into v_wal from pg_ls_waldir(); exception when others then v_wal := 0; end;
  v_plan := (coalesce(silver.cfg('storage_plan_gb'),8) * 1024^3)::bigint;
  return query select v_db, v_wal, v_db+v_wal, v_plan, round(100.0*(v_db+v_wal)/v_plan,2),
     case when 100.0*(v_db+v_wal)/v_plan >= v_c then 'critical' when 100.0*(v_db+v_wal)/v_plan >= v_w then 'warning' else 'ok' end;
end $function$
;

CREATE OR REPLACE FUNCTION silver.sync_canonical_attrs()
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
AS $function$
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
        variant_key = nullif((x.f).variant_key, ''), product_type = x.product_type, size_value = x.size_value,
        size_unit = x.size_unit, pack_count = x.pack_count,
        category_l1 = (x.f).cat_l1, category_l2 = (x.f).cat_l2, category_l3 = (x.f).cat_l3
    from x
    where x.sidnl_id = c.sidnl_id
      and (c.canonical_name, c.name_clean, c.variant, c.variant_key, c.product_type, c.size_value, c.size_unit,
           c.pack_count, c.category_l1, c.category_l2, c.category_l3)
          is distinct from
          (x.product_name, (x.f).name_clean, x.variant, nullif((x.f).variant_key, ''), x.product_type, x.size_value, x.size_unit,
           x.pack_count, (x.f).cat_l1, (x.f).cat_l2, (x.f).cat_l3);
    get diagnostics n = row_count;
    return n;
end $function$
;

CREATE OR REPLACE FUNCTION silver.token_set_sim(a text, b text)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
AS $function$
declare ta text[]; tb text[]; inter text[]; da text[]; db text[]; si text; s1 text; s2 text;
begin
    if coalesce(a, '') = '' and coalesce(b, '') = '' then return 1; end if;
    if coalesce(a, '') = '' or coalesce(b, '') = '' then return 0; end if;
    ta := string_to_array(a, ' '); tb := string_to_array(b, ' ');
    inter := array(select x from unnest(ta) x intersect select y from unnest(tb) y order by 1);
    if cardinality(inter) = 0 then return round(similarity(a, b)::numeric, 4); end if;
    da := array(select x from unnest(ta) x except select y from unnest(tb) y order by 1);
    db := array(select y from unnest(tb) y except select x from unnest(ta) x order by 1);
    if cardinality(da) = 0 or cardinality(db) = 0 then return 1; end if;
    si := array_to_string(inter, ' ');
    s1 := si || ' ' || array_to_string(da, ' ');
    s2 := si || ' ' || array_to_string(db, ' ');
    return round(greatest(similarity(si, s1), similarity(si, s2), similarity(s1, s2))::numeric, 4);
end $function$
;

CREATE OR REPLACE FUNCTION silver.unmap_product(p_product_key integer, p_by text DEFAULT SESSION_USER)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'ops', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_new text;
begin
    perform pg_advisory_xact_lock(727102);
    v_new := silver.new_canonical(p_product_key, 'manual');
    update silver.product_xref set sidnl_id = v_new, match_status = 'MANUAL', match_method = 'MANUAL_SPLIT',
           reviewed_by = p_by, reviewed_at = now()
     where product_key = p_product_key;
    if not found then raise exception 'product_key % has no SI id yet', p_product_key; end if;
    return v_new;
end $function$
;

comment on function dash.refresh(p_visibility_days integer) is 'Rebuilds dash.pricing and dash.availability fully and dash.visibility for the last N days (NULL = all). overview/ads/supply are loaded by their own feeds.';

comment on function ops.alert_claim(p_limit integer) is 'alert-dispatch: returns up to p_limit due pending rows and marks them sending; returns nothing while alert_delivery_enabled = 0.';

comment on function ops.alert_mark(p_alert_id bigint, p_ok boolean, p_err text) is 'alert-dispatch: marks a row sent, or schedules a retry (silver.backoff_minutes) / marks it dead after alert_max_attempts.';

comment on function ops.heartbeat() is 'Rows of ops.v_heartbeat for the heartbeat edge function (service_role only).';

comment on function public.sidnl_heartbeat(p_token text) is 'Uptime-monitor endpoint (silver_067): GET /rest/v1/rpc/sidnl_heartbeat?p_token=... answers 200 when every sidnl-* cron job is active, on time and its last run did not fail, 503 otherwise, 401 without the Vault token heartbeat_token.';

comment on function silver.auto_approve_exact_matches() is 'sidnl-auto-match: approves only exact cross-platform twins from match_review_queue (see silver_058). Fuzzy matches stay for review.';

comment on function silver.deliver_alerts() is 'sidnl-alerts (every minute): settle earlier Slack sends, then post due outbox rows. Off while alert_delivery_enabled = 0 or the Vault secret slack_webhook_url is missing.';

comment on function silver.dq_checks(p_shelf_max bigint) is 'Severity-classified silver checks. blocks=true means the affected scope must not advance its watermark. scope=all rows are roll-ups.';

comment on function silver.enqueue_daily_safe(p_reason text) is 'silver.enqueue_daily with a 5 s lock_timeout; a lock wait or duplicate returns null instead of failing the cron job (the 18:35 UTC job timed out on 2026-11-09).';

comment on function silver.enrich_product_categories() is 'Fills dim_product.category_key with the deepest scraped category (breadcrumb L1>L2>L3, else shelf L1>L2). Never invents a level.';

comment on function silver.exact_key(p_name text, p_pack text) is 'Normalised name + pack. Two listings of one brand with the same key are the same product (any platform).';

comment on function silver.fill_store_cities() is 'sidnl-store-city: gives a city-less store the single city its bronze snapshots report, then sets that city on its facts (silver_060).';

comment on function silver.merge_exact_duplicates(p_by text) is 'Collapses SI ids whose products have the same brand + normalised name + normalised pack into the oldest SI id.';

comment on function silver.onboard_brands() is 'company_brands -> brand_scope, once the brand name is seen in bronze. Add extra spellings to brand_scope.raw_brand_aliases.';

comment on function silver.parse_pack(p_pack text) is 'Pack text -> (size_value in base g/ml/pc, size_unit, pack_count).';

comment on function silver.parse_variant(p_name text, p_brand text, p_ptype text) is 'Product name minus brand / product type / pack text.';

comment on function silver.quality_checks() is 'Parser/matcher self-tests plus map invariants. Every row must have ok = true.';

comment on function silver.reading_dq(p_has_product boolean, p_has_store boolean, p_observed timestamp with time zone, p_status text, p_inventory integer, p_price numeric, p_mrp numeric) is 'DQ flags for one reading; see silver.dq_status().';

comment on function silver.reconcile() is 'sidnl-reconcile (daily): bronze -> silver -> dash reconciliation; see ops.v_reconciliation_latest (silver_061).';

comment on function silver.refresh_all() is 'Runs refresh_brand() for every enabled brand in silver.brand_scope.';

comment on function silver.refresh_brand(p_brand_key text, p_full boolean) is 'Parser + cleaning for one brand. p_full=false reads only bronze rows newer than the watermark (less a look-back); a brand never loaded before is loaded in full.';

comment on function silver.refresh_category_market(p_full boolean) is 'Category shelf cards -> fact_shelf_position (+ products via refresh_category_products). Incremental; a new category is loaded in full.';

comment on function silver.refresh_freshness() is 'sidnl-freshness (every 5 min): bronze freshness per platform x source, incremental by id cursor (silver_062).';

comment on function silver.register_category_scopes() is 'Adds every category shelf read OK at >= category_min_stores stores (or by a done sweep of that size) to category_scope. Run by run_pipeline() on every tick.';

comment on function silver.register_platforms() is 'Adds platforms found in bronze to dim_platform (is_test=false). Existing rows, e.g. the team''s demo platform, are untouched.';

comment on function silver.resequence_sidnl() is 'Keeps SI ids strictly alphabetical by canonical product name. Called by run_pipeline after matching; no-op when already ordered.';

comment on function silver.run_maintenance() is 'sidnl-maintenance (daily): purge old cron.job_run_details, analyze silver/dash tables that have no planner statistics.';

comment on function silver.run_pipeline(p_force boolean, p_trigger text) is 'Automatic bronze -> silver -> SI ids -> gold. p_force = run even with no new data. Called every minute by pg_cron.';

comment on function silver.send_test_alert() is 'Owner helper: queues one info alert to verify Slack delivery end to end.';

comment on function silver.sidnl_everything(p_id text, p_row_limit integer) is 'All rows for one SI id across every silver/gold table and platform, as jsonb.';

comment on function silver.slack_text(p_severity text, p_title text, p_body text, p_source text) is 'Slack message text for an alert: *[SIDNL severity]* title, body, source; & < > escaped for Slack.';

revoke all on function ops.alert_claim(p_limit integer) from public;
do $g$ begin if exists (select 1 from pg_roles where rolname = 'service_role') then grant execute on function ops.alert_claim(p_limit integer) to service_role; end if; end $g$;

revoke all on function ops.alert_mark(p_alert_id bigint, p_ok boolean, p_err text) from public;
do $g$ begin if exists (select 1 from pg_roles where rolname = 'service_role') then grant execute on function ops.alert_mark(p_alert_id bigint, p_ok boolean, p_err text) to service_role; end if; end $g$;

revoke all on function ops.cron_alert_to_outbox() from public;

revoke all on function ops.heartbeat() from public;
do $g$ begin if exists (select 1 from pg_roles where rolname = 'service_role') then grant execute on function ops.heartbeat() to service_role; end if; end $g$;

revoke all on function ops.storage_alert_to_outbox() from public;

revoke all on function public.sidnl_heartbeat(p_token text) from public;
do $g$ begin if exists (select 1 from pg_roles where rolname = 'anon') then grant execute on function public.sidnl_heartbeat(p_token text) to anon; end if; end $g$;
do $g$ begin if exists (select 1 from pg_roles where rolname = 'authenticated') then grant execute on function public.sidnl_heartbeat(p_token text) to authenticated; end if; end $g$;
do $g$ begin if exists (select 1 from pg_roles where rolname = 'service_role') then grant execute on function public.sidnl_heartbeat(p_token text) to service_role; end if; end $g$;

revoke all on function silver.deliver_alerts() from public;

revoke all on function silver.send_test_alert() from public;
