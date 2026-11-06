-- =============================================================================
-- File:    silver/005_views.sql
-- Purpose: Read-side views over the silver star schema.
--
--   v_reading           every reading, fully denormalised, with age + fresh/stale label
--   v_reading_current   latest VALID reading per (product, store)  -> "current state"
--   v_data_freshness    per source: how fresh is the data right now?
--   v_dq_summary        data-quality flag counts
--   v_sku_listing       dark-store listing % per product x city (+ ALL)
--
-- Fresh vs stale is computed against now() and silver.freshness_policy, so the
-- label ages automatically and no reload is needed.
-- =============================================================================

create or replace view silver.v_reading as
select f.reading_key, f.source_type, f.source_record_id, f.job_ref,
       f.observed_at, f.obs_date,
       p.platform,
       b.brand_key, b.brand_name, b.company_name,
       p.product_key, p.platform_product_id, p.product_name, p.variant, p.product_type,
       p.pack_raw, p.size_value, p.size_unit, p.pack_count,
       c.l1_id, c.l1_name as l1_category, c.l2_id, c.l2_name as l2_category,
       c.l3_id, c.l3_name as l3_category, c.category_path,
       s.store_key, s.source_store_id, s.store_external_id, s.store_name,
       f.city_slug, ct.city_name, ct.state, s.latitude, s.longitude,
       f.stock_status, f.is_listed, f.is_available, f.inventory_units, f.inventory_is_capped,
       f.selling_price, f.mrp, f.discount_amount, f.discount_pct,
       f.search_position, f.organic_position, f.is_ad, f.ad_type,
       f.osa_eligible, f.dq_status, f.dq_flags,
       round(extract(epoch from (now() - f.observed_at)) / 3600, 1)               as age_hours,
       case when f.observed_at >= now() - make_interval(hours => fp.fresh_within_hours)
            then 'fresh' else 'stale' end                                          as freshness
from silver.fact_product_reading f
join silver.dim_product p          on p.product_key = f.product_key
join silver.dim_brand b            on b.brand_key = p.brand_key
join silver.freshness_policy fp    on fp.source_type = f.source_type
left join silver.dim_category c    on c.category_key = p.category_key
left join silver.dim_store s       on s.store_key = f.store_key
left join silver.dim_city ct       on ct.city_slug = f.city_slug;
comment on view silver.v_reading is 'Denormalised readings with age_hours and freshness (fresh|stale per silver.freshness_policy). Includes all dq_status values - filter dq_status=''valid'' for metrics.';

create or replace view silver.v_reading_current as
select distinct on (r.product_key, r.store_key) r.*
from silver.v_reading r
where r.dq_status = 'valid' and r.store_key is not null
order by r.product_key, r.store_key, r.observed_at desc, r.reading_key desc;
comment on view silver.v_reading_current is 'Latest valid reading per (product, store) across all sources: the current FE inventory / price / availability picture. Check freshness before trusting it.';

create or replace view silver.v_data_freshness as
select r.platform, r.brand_key, r.source_type,
       count(*)                                                   as readings,
       count(*) filter (where r.freshness = 'fresh')              as fresh_readings,
       count(*) filter (where r.freshness = 'stale')              as stale_readings,
       round(100.0 * count(*) filter (where r.freshness = 'fresh') / count(*), 1) as pct_fresh,
       min(r.observed_at)                                         as first_observed_at,
       max(r.observed_at)                                         as last_observed_at,
       round(extract(epoch from (now() - max(r.observed_at))) / 3600, 1) as hours_since_last_reading,
       fp.fresh_within_hours,
       case when max(r.observed_at) >= now() - make_interval(hours => fp.fresh_within_hours)
            then 'fresh' else 'stale' end                         as source_status
from silver.v_reading r
join silver.freshness_policy fp on fp.source_type = r.source_type
group by r.platform, r.brand_key, r.source_type, fp.fresh_within_hours;
comment on view silver.v_data_freshness is 'Per platform x brand x source: reading counts split fresh/stale, and whether the source as a whole is still fresh.';

create or replace view silver.v_dq_summary as
select p.platform, p.brand_key, f.source_type, f.dq_status, flag.f as dq_flag, count(*) as readings
from silver.fact_product_reading f
join silver.dim_product p on p.product_key = f.product_key
cross join lateral unnest(case when cardinality(f.dq_flags) = 0 then array['(none)'] else f.dq_flags end) as flag(f)
group by p.platform, p.brand_key, f.source_type, f.dq_status, flag.f;
comment on view silver.v_dq_summary is 'How many readings carry each data-quality flag.';

-- ---------------------------------------------------------------------------
-- Dark-store listing % (PDF section 2):  stores listing the SKU / eligible stores.
--   eligible store  = a store whose LATEST valid brand-search scan succeeded
--   listing store   = eligible store whose latest scan returned a card for the SKU
-- city_slug = 'ALL' is the roll-up across cities.
-- CAVEAT: scans flagged stopped_early may miss cards, so listing % is a floor;
--         eligible_stores_stopped_early shows how much of the base that affects.
-- ---------------------------------------------------------------------------
create or replace view silver.v_sku_listing as
with latest_scan as (
    select distinct on (s.brand_key, s.store_key)
           s.brand_key, s.store_key, s.snapshot_id, s.platform, s.scanned_at, s.stopped_early,
           coalesce(s.city_slug, '(unknown)') as city_slug
    from silver.fact_store_scan s
    where s.is_valid_denominator
    order by s.brand_key, s.store_key, s.scanned_at desc, s.snapshot_id desc
),
eligible as (
    select platform, brand_key, coalesce(city_slug, 'ALL') as city_slug,
           count(*)                              as eligible_stores,
           count(*) filter (where stopped_early) as eligible_stores_stopped_early,
           max(scanned_at)                       as latest_scan_at
    from latest_scan
    group by platform, brand_key, rollup (city_slug)
),
listed as (
    select ls.platform, ls.brand_key, coalesce(ls.city_slug, 'ALL') as city_slug,
           f.product_key, count(distinct ls.store_key) as listing_stores
    from latest_scan ls
    join silver.fact_product_reading f
      on f.snapshot_id = ls.snapshot_id and f.source_type = 'brand_search'
     and f.dq_status = 'valid' and f.is_listed
    group by ls.platform, ls.brand_key, f.product_key, rollup (ls.city_slug)
)
select p.platform, p.brand_key, p.product_key, p.platform_product_id, p.product_name,
       e.city_slug, e.eligible_stores,
       coalesce(l.listing_stores, 0)                                       as listing_stores,
       round(100.0 * coalesce(l.listing_stores, 0) / nullif(e.eligible_stores, 0), 2) as listing_pct,
       e.eligible_stores_stopped_early,
       e.latest_scan_at
from silver.dim_product p
join eligible e on e.platform = p.platform and e.brand_key = p.brand_key
left join listed l on l.product_key = p.product_key and l.city_slug = e.city_slug;
comment on view silver.v_sku_listing is 'Dark-store listing % per SKU x city (+ALL) from the latest valid scan of every store. listing_pct = listing_stores / eligible_stores x 100.';
