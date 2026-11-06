-- =============================================================================
-- File:    gold/007_gold_brand_product.sql
-- Purpose: Brand, product, and SKU-level rollup metrics.
-- Run as:  postgres (Supabase SQL Editor)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- A. BRAND SUMMARY — overall performance per brand × platform × date
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS gold.mv_brand_daily CASCADE;

CREATE MATERIALIZED VIEW gold.mv_brand_daily AS
SELECT
    obs_date,
    platform,
    brand,

    -- Assortment
    COUNT(DISTINCT effective_sku_key)                                AS distinct_skus,
    COUNT(DISTINCT city_slug)                                        AS distinct_cities,
    COUNT(DISTINCT store_id)                                         AS distinct_stores,

    -- Availability (observations only)
    COUNT(*) FILTER (WHERE source_type = 'observation')              AS total_obs,
    COUNT(*) FILTER (WHERE source_type = 'observation'
                       AND availability = true)                      AS available_obs,
    ROUND(
        100.0
        * COUNT(*) FILTER (WHERE source_type = 'observation' AND availability = true)
        / NULLIF(COUNT(*) FILTER (WHERE source_type = 'observation'), 0),
        2
    )                                                                AS osa_pct,

    -- Pricing (observations only)
    ROUND(AVG(mrp)   FILTER (WHERE source_type = 'observation')::numeric, 2)
                                                                     AS avg_mrp,
    ROUND(AVG(sale_price) FILTER (WHERE source_type = 'observation')::numeric, 2)
                                                                     AS avg_sp,
    ROUND(AVG(
        CASE WHEN mrp > 0 AND sale_price IS NOT NULL
             THEN (mrp - sale_price) / mrp * 100
             ELSE NULL END
    ) FILTER (WHERE source_type = 'observation')::numeric, 2)        AS avg_discount_pct,

    -- Shelf (shelf_positions only)
    COUNT(*) FILTER (WHERE source_type = 'shelf_position')           AS total_shelf_positions,
    ROUND(AVG(position) FILTER (WHERE source_type = 'shelf_position')::numeric, 1)
                                                                     AS avg_position,
    ROUND(100.0
        * COUNT(*) FILTER (WHERE source_type = 'shelf_position' AND is_ad = true)
        / NULLIF(COUNT(*) FILTER (WHERE source_type = 'shelf_position'), 0),
        2)                                                           AS ad_share_pct

FROM gold._base_silver
GROUP BY obs_date, platform, brand
WITH DATA;

CREATE INDEX ix_mv_brand_daily_date_platform ON gold.mv_brand_daily (obs_date, platform);
CREATE INDEX ix_mv_brand_daily_brand         ON gold.mv_brand_daily (brand);

COMMENT ON MATERIALIZED VIEW gold.mv_brand_daily IS
    'Daily brand rollup: OSA, pricing, shelf across both source_types. '
    'Refresh with: REFRESH MATERIALIZED VIEW gold.mv_brand_daily;';


-- ---------------------------------------------------------------------------
-- B. SKU / PRODUCT SUMMARY — per SKU × platform (all-time)
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS gold.mv_sku_summary CASCADE;

CREATE MATERIALIZED VIEW gold.mv_sku_summary AS
SELECT
    platform,
    effective_sku_key,
    MAX(product_name)                                                AS product_name,
    MAX(brand)                                                       AS brand,
    MAX(l1_category)                                                 AS l1_category,
    MAX(l2_category)                                                 AS l2_category,
    MAX(l3_category)                                                 AS l3_category,

    -- Date range
    MIN(obs_date)                                                    AS first_seen_date,
    MAX(obs_date)                                                    AS last_seen_date,
    COUNT(DISTINCT obs_date)                                         AS active_days,

    -- Coverage
    COUNT(DISTINCT city_slug)                                        AS city_count,
    COUNT(DISTINCT store_id)                                         AS store_count,

    -- Availability (observations)
    COUNT(*) FILTER (WHERE source_type = 'observation')              AS total_obs,
    COUNT(*) FILTER (WHERE source_type = 'observation' AND availability = true)
                                                                     AS available_obs,
    ROUND(
        100.0
        * COUNT(*) FILTER (WHERE source_type = 'observation' AND availability = true)
        / NULLIF(COUNT(*) FILTER (WHERE source_type = 'observation'), 0),
        2
    )                                                                AS lifetime_osa_pct,

    -- Pricing range
    ROUND(MIN(mrp) FILTER (WHERE source_type = 'observation')::numeric, 2)  AS min_mrp,
    ROUND(MAX(mrp) FILTER (WHERE source_type = 'observation')::numeric, 2)  AS max_mrp,
    ROUND(AVG(mrp) FILTER (WHERE source_type = 'observation')::numeric, 2)  AS avg_mrp,
    ROUND(MIN(sale_price) FILTER (WHERE source_type = 'observation')::numeric, 2) AS min_sp,
    ROUND(MAX(sale_price) FILTER (WHERE source_type = 'observation')::numeric, 2) AS max_sp,
    ROUND(AVG(sale_price) FILTER (WHERE source_type = 'observation')::numeric, 2) AS avg_sp,
    ROUND(AVG(discount_pct) FILTER (WHERE source_type = 'observation')::numeric, 2)
                                                                     AS avg_discount_pct,

    -- Shelf appearance
    COUNT(*) FILTER (WHERE source_type = 'shelf_position')           AS shelf_appearances,
    ROUND(AVG(position) FILTER (WHERE source_type = 'shelf_position')::numeric, 1)
                                                                     AS avg_shelf_position,
    COUNT(*) FILTER (WHERE source_type = 'shelf_position' AND is_ad = true)
                                                                     AS ad_appearances

FROM gold._base_silver
GROUP BY platform, effective_sku_key
WITH DATA;

CREATE INDEX ix_mv_sku_summary_platform ON gold.mv_sku_summary (platform);
CREATE INDEX ix_mv_sku_summary_brand    ON gold.mv_sku_summary (brand);
CREATE INDEX ix_mv_sku_summary_l1       ON gold.mv_sku_summary (l1_category);
CREATE INDEX ix_mv_sku_summary_sku      ON gold.mv_sku_summary (effective_sku_key);

COMMENT ON MATERIALIZED VIEW gold.mv_sku_summary IS
    'All-time SKU-level summary per platform: OSA, pricing, shelf, coverage. '
    'Refresh with: REFRESH MATERIALIZED VIEW gold.mv_sku_summary;';
