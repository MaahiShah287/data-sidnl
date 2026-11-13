-- dash_015: SI id (sidnl_id) mapping in dash, derived only from silver (silver.product_xref / silver.dim_product).
--
-- Why: silver.resequence_sidnl() renumbers SI ids (they are kept A-Z by product name), so an SI id copied into a table that is
--   refreshed on its own schedule goes stale. Checked 2026-11-13 07:10 UTC: 4,333 of 16,204 dash.comp_sku_day rows (27 %)
--   carried an sidnl_id that no longer equals silver.product_xref.sidnl_id for their product_key.
--   The stable key is product_key (one platform listing); silver.product_xref is unique on it, so a join cannot duplicate rows.
--
-- What changes (every mapping below is an exact join, nothing is inferred):
--   1. dash.comp_sku_day            stops storing sidnl_id; new view dash.v_comp_sku_day resolves it live through product_xref
--                                   (dash.refresh_competitors() is patched, dash.v_comp_cross_marketplace rebuilt on the view)
--   2. dash.v_valid_reading         gains sidnl_id (last column) via product_xref: every reading has a product_key
--   3. dash.cfg_sku                 new view dash.v_cfg_sku: platform_product_id -> silver.dim_product -> product_xref -> sidnl_id
--   4. dash.ads.sidnl_id            NOT mapped on purpose: the ad exports carry campaign + keyword / placement only, no product
--                                   (contracts/sidnl_data_contract_v1.md: "SKU-level ads report ... awaiting first export").
--                                   A column comment records this so nobody fills it with a guess.
--   Not product grain, so no sidnl_id by design: ads_campaign_period, ads_keyword_sov, coverage, collection_health, comp_brand_day,
--   v_brand_scorecard*, v_comp_price_gap (brand level), dim_store / dim_city / dim_category / dim_date / dim_platform, cfg_threshold,
--   cfg_workspace_map, metric_catalog, refresh_*.

do $pre$
begin
    if to_regclass('silver.product_xref') is null or to_regclass('silver.dim_product') is null then
        raise exception 'dash_015 preflight: silver.product_xref / silver.dim_product missing';
    end if;
    if exists (select 1 from silver.product_xref group by product_key having count(*) > 1) then
        raise exception 'dash_015 preflight: silver.product_xref has more than one row for a product_key; a join would duplicate rows';
    end if;
    if exists (select 1 from silver.dim_product group by platform, platform_product_id having count(*) > 1) then
        raise exception 'dash_015 preflight: silver.dim_product is not unique on (platform, platform_product_id)';
    end if;
end
$pre$;

-- ---- 1. competitor SKU table: product_key stays, sidnl_id is resolved at read time ----------------------------------
drop view if exists dash.v_comp_cross_marketplace;
drop index if exists dash.comp_sku_day_sidnl_idx;
alter table dash.comp_sku_day drop column if exists sidnl_id;

do $mig$
declare v_def text; v_new text;
begin
    v_def := pg_get_functiondef('dash.refresh_competitors()'::regprocedure);
    v_new := replace(v_def, 'product_key, sidnl_id, brand_key, brand_name,', 'product_key, brand_key, brand_name,');
    v_new := replace(v_new, 'dp.total_content, x.sidnl_id,', 'dp.total_content,');
    v_new := replace(v_new, E'\n              left join silver.product_xref x on x.product_key = a.product_key', '');
    if position('sidnl_id' in v_new) > 0 or position('product_xref' in v_new) > 0 then
        raise exception 'dash_015: dash.refresh_competitors still mentions sidnl_id / product_xref after the patch';
    end if;
    if v_new = v_def then
        raise exception 'dash_015: dash.refresh_competitors was not changed';
    end if;
    execute v_new;
end
$mig$;

create or replace view dash.v_comp_sku_day with (security_invoker = true) as
select c.*, x.sidnl_id
  from dash.comp_sku_day c
  left join silver.product_xref x on x.product_key = c.product_key;
comment on view dash.v_comp_sku_day is
    'dash.comp_sku_day plus the CURRENT sidnl_id of the product (silver.product_xref, joined on product_key at read time, because SI ids are renumbered by silver.resequence_sidnl and a stored copy goes stale).';

create or replace view dash.v_comp_cross_marketplace with (security_invoker = true) as
with latest as (
    select distinct on (platform, city_slug, sidnl_id)
           platform, city_slug, sidnl_id, brand_key, brand_name, product_name, pack_raw, obs_date,
           sp_median, mrp_median, price_per_100, price_unit
      from dash.v_comp_sku_day
     where sidnl_id is not null and sp_median is not null
     order by platform, city_slug, sidnl_id, obs_date desc),
multi as (select city_slug, sidnl_id from latest group by 1, 2 having count(distinct platform) >= 2)
select l.sidnl_id, l.city_slug, max(l.brand_name) as brand_name, max(l.product_name) as product_name,
       max(l.pack_raw) as pack_raw,
       min(l.sp_median) as min_sp, max(l.sp_median) as max_sp,
       max(l.sp_median) - min(l.sp_median) as price_gap,
       round(100 * (max(l.sp_median) - min(l.sp_median)) / nullif(min(l.sp_median), 0), 2) as price_gap_pct,
       (array_agg(l.platform order by l.sp_median asc,  l.platform))[1] as cheapest_platform,
       (array_agg(l.platform order by l.sp_median desc, l.platform))[1] as dearest_platform,
       jsonb_object_agg(l.platform, l.sp_median) as sp_by_platform,
       jsonb_object_agg(l.platform, l.obs_date)  as obs_date_by_platform
  from latest l join multi m using (city_slug, sidnl_id)
 group by l.sidnl_id, l.city_slug;
comment on view dash.v_comp_cross_marketplace is
    'Handbook 113: same SI id on two platforms in one city. Gap % = (max SP - min SP) / min SP. Dates per platform are in obs_date_by_platform (scrape days can differ). SI id is resolved live from silver.product_xref.';

alter view dash.v_comp_price_gap set (security_invoker = true);
comment on table dash.comp_sku_day is
    'Competitor layer: one SKU x city x day from category-shelf scrapes (all brands that share a shelf with a client brand). sp_median = median over the stores that listed it; osa_pct = in_stock_obs / valid_obs. No sidnl_id here (it is renumbered by the pipeline): read dash.v_comp_sku_day.';

-- ---- 2. dash.v_valid_reading: add the SI id of the reading's product (appended as the last column) ----------------------
create or replace view dash.v_valid_reading with (security_invoker = true) as
select r.reading_key, r.source_type, r.source_record_id, r.job_ref, r.observed_at, r.obs_date, r.platform, r.brand_key,
       r.brand_name, r.company_name, r.product_key, r.platform_product_id, r.product_name, r.variant, r.product_type,
       r.pack_raw, r.size_value, r.size_unit, r.pack_count, r.l1_id, r.l1_category, r.l2_id, r.l2_category, r.l3_id,
       r.l3_category, r.category_path, r.store_key, r.source_store_id, r.store_external_id, r.store_name, r.city_slug,
       r.city_name, r.state, r.latitude, r.longitude, r.stock_status, r.is_listed, r.is_available, r.inventory_units,
       r.inventory_is_capped, r.selling_price, r.mrp, r.discount_amount, r.discount_pct, r.search_position,
       r.organic_position, r.is_ad, r.ad_type, r.osa_eligible, r.dq_status, r.dq_flags, r.age_hours, r.freshness,
       x.sidnl_id
  from silver.v_reading r
  join silver.dim_platform dp on dp.platform = r.platform and not dp.is_test
  left join silver.product_xref x on x.product_key = r.product_key
 where r.dq_status = 'valid';
comment on view dash.v_valid_reading is
    'silver.v_reading limited to dq_status=valid and non-test platforms. Single entry point for all gold metrics. sidnl_id (dash_015) = silver.product_xref.sidnl_id of the reading''s product_key, resolved at read time.';

-- ---- 3. dash.cfg_sku (client target list, keyed by platform product id) -> SI id --------------------------------------
create or replace view dash.v_cfg_sku with (security_invoker = true) as
select c.platform, c.platform_product_id, c.brand_key, c.is_target, c.threshold_sp, c.notes,
       p.product_key, x.sidnl_id, (x.sidnl_id is not null) as is_mapped
  from dash.cfg_sku c
  left join silver.dim_product p on p.platform = c.platform and p.platform_product_id = c.platform_product_id
  left join silver.product_xref x on x.product_key = p.product_key;
comment on view dash.v_cfg_sku is
    'dash.cfg_sku plus the product and SI id it resolves to in silver (platform + platform_product_id -> dim_product -> product_xref). is_mapped = false: the platform product id is not in silver.dim_product yet.';

-- ---- 4. ads: record why sidnl_id is NULL, so it is never filled with a guess -------------------------------------------
comment on column dash.ads.sidnl_id is
    'NULL by design. The ad-console exports carry campaign + keyword / placement only, no product or SKU, so an SI id cannot be derived (0 of 70 Asset values match a platform_product_id or product name). Filled only from a SKU-level ads report (contracts/sidnl_data_contract_v1.md). Brand linkage: dash.cfg_workspace_map / dash.v_workspace_ads.';
