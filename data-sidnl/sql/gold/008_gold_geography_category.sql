-- =============================================================================
-- File:    gold/008_gold_geography_category.sql
-- Purpose: Geography (city/store) and Category (L1/L2/L3) metrics.
-- Run as:  postgres (Supabase SQL Editor)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- A. GEOGRAPHY — daily metrics per city × platform
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS gold.mv_geography_daily CASCADE;

CREATE MATERIALIZED VIEW gold.mv_geography_daily AS
SELECT
    obs_date,
    platform,
    city_slug,
    -- Availability (observations)
    COUNT(*) FILTER (WHERE source_type = 'observation')              AS total_obs,
    COUNT(*) FILTER (WHERE source_type = 'observation' AND availability = true)
                                                                     AS available_obs,
    ROUND(100.0
        * COUNT(*) FILTER (WHERE source_type = 'observation' AND availability = true)
        / NULLIF(COUNT(*) FILTER (WHERE source_type = 'observation'), 0), 2)
                                                                     AS osa_pct,
    -- Distinct dimensions
    COUNT(DISTINCT effective_sku_key)                                AS distinct_skus,
    COUNT(DISTINCT brand)                                            AS distinct_brands,
    COUNT(DISTINCT store_id)                                         AS distinct_stores,
    -- Pricing
    ROUND(AVG(mrp)   FILTER (WHERE source_type = 'observation')::numeric, 2)
                                                                     AS avg_mrp,
    ROUND(AVG(sale_price) FILTER (WHERE source_type = 'observation')::numeric, 2)
                                                                     AS avg_sp,
    -- Inventory
    SUM(inventory) FILTER (WHERE source_type = 'observation')       AS total_fe_inventory

FROM gold._base_silver
GROUP BY obs_date, platform, city_slug
WITH DATA;

CREATE INDEX ix_mv_geo_daily_date_platform ON gold.mv_geography_daily (obs_date, platform);
CREATE INDEX ix_mv_geo_daily_city          ON gold.mv_geography_daily (city_slug);

COMMENT ON MATERIALIZED VIEW gold.mv_geography_daily IS
    'Daily city × platform rollup: OSA, assortment, pricing, inventory. '
    'Refresh with: REFRESH MATERIALIZED VIEW gold.mv_geography_daily;';


-- ---------------------------------------------------------------------------
-- B. STORE-LEVEL SNAPSHOT — per store × platform (current state)
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS gold.v_store_snapshot CASCADE;

CREATE OR REPLACE VIEW gold.v_store_snapshot AS
SELECT
    platform,
    store_id,
    store_name,
    store_external_id,
    city_slug,
    city,
    state,
    pincode,
    latitude,
    longitude,
    COUNT(DISTINCT effective_sku_key)                                AS total_skus,
    COUNT(DISTINCT effective_sku_key) FILTER (WHERE availability = true)
                                                                     AS available_skus,
    ROUND(100.0
        * COUNT(DISTINCT effective_sku_key) FILTER (WHERE availability = true)
        / NULLIF(COUNT(DISTINCT effective_sku_key), 0), 2)           AS osa_pct,
    ROUND(AVG(mrp)::numeric, 2)                                      AS avg_mrp,
    ROUND(AVG(sale_price)::numeric, 2)                               AS avg_sp,
    SUM(inventory)                                                   AS total_fe_inventory,
    MAX(observed_at)                                                 AS last_observed_at
FROM gold._base_silver
WHERE source_type = 'observation'
GROUP BY platform, store_id, store_name, store_external_id,
         city_slug, city, state, pincode, latitude, longitude;

COMMENT ON VIEW gold.v_store_snapshot IS
    'Store-level snapshot: OSA, assortment, pricing, inventory. All-time observations.';


-- ---------------------------------------------------------------------------
-- C. CATEGORY — daily metrics per L1 × L2 × platform
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS gold.mv_category_daily CASCADE;

CREATE MATERIALIZED VIEW gold.mv_category_daily AS
SELECT
    obs_date,
    platform,
    COALESCE(l1_category, 'Unknown') AS l1_category,
    COALESCE(l2_category, 'Unknown') AS l2_category,
    l3_category,                          -- intentionally NULL when missing

    -- Assortment
    COUNT(DISTINCT effective_sku_key)                                AS distinct_skus,
    COUNT(DISTINCT brand)                                            AS distinct_brands,
    COUNT(DISTINCT city_slug)                                        AS distinct_cities,
    COUNT(DISTINCT store_id)                                         AS distinct_stores,

    -- Availability (observations only)
    COUNT(*) FILTER (WHERE source_type = 'observation')              AS total_obs,
    COUNT(*) FILTER (WHERE source_type = 'observation' AND availability = true)
                                                                     AS available_obs,
    ROUND(100.0
        * COUNT(*) FILTER (WHERE source_type = 'observation' AND availability = true)
        / NULLIF(COUNT(*) FILTER (WHERE source_type = 'observation'), 0), 2)
                                                                     AS osa_pct,

    -- Pricing
    ROUND(AVG(mrp)   FILTER (WHERE source_type = 'observation')::numeric, 2)
                                                                     AS avg_mrp,
    ROUND(AVG(sale_price) FILTER (WHERE source_type = 'observation')::numeric, 2)
                                                                     AS avg_sp,
    ROUND(AVG(
        CASE WHEN mrp > 0 AND sale_price IS NOT NULL
             THEN (mrp - sale_price) / mrp * 100
             ELSE NULL END
    ) FILTER (WHERE source_type = 'observation')::numeric, 2)        AS avg_discount_pct,

    -- Shelf
    COUNT(*) FILTER (WHERE source_type = 'shelf_position')           AS shelf_positions,
    ROUND(AVG(position) FILTER (WHERE source_type = 'shelf_position')::numeric, 1)
                                                                     AS avg_position,
    ROUND(100.0
        * COUNT(*) FILTER (WHERE source_type = 'shelf_position' AND is_ad = true)
        / NULLIF(COUNT(*) FILTER (WHERE source_type = 'shelf_position'), 0), 2)
                                                                     AS ad_share_pct

FROM gold._base_silver
GROUP BY obs_date, platform, l1_category, l2_category, l3_category
WITH DATA;

CREATE INDEX ix_mv_cat_daily_date_platform ON gold.mv_category_daily (obs_date, platform);
CREATE INDEX ix_mv_cat_daily_l1            ON gold.mv_category_daily (l1_category);
CREATE INDEX ix_mv_cat_daily_l2            ON gold.mv_category_daily (l2_category);

COMMENT ON MATERIALIZED VIEW gold.mv_category_daily IS
    'Daily L1/L2/L3 category rollup: assortment, OSA, pricing, shelf. '
    'Refresh with: REFRESH MATERIALIZED VIEW gold.mv_category_daily;';
