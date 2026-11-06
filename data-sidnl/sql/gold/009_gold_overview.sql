-- =============================================================================
-- File:    gold/009_gold_overview.sql
-- Purpose: Top-level overview KPI views — the portal's first-load dashboard.
-- Run as:  postgres (Supabase SQL Editor)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- A. PLATFORM OVERVIEW — one row per platform (current state summary)
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS gold.mv_platform_overview CASCADE;

CREATE MATERIALIZED VIEW gold.mv_platform_overview AS
SELECT
    platform,
    -- Assortment
    COUNT(DISTINCT effective_sku_key)                                      AS total_skus,
    COUNT(DISTINCT brand)                                                  AS total_brands,
    COUNT(DISTINCT COALESCE(l1_category, 'Unknown'))                       AS total_l1_categories,
    COUNT(DISTINCT NULLIF(CONCAT(COALESCE(l1_category,''), '|',
                                 COALESCE(l2_category,'')), '|'))          AS total_l2_categories,
    COUNT(DISTINCT city_slug)                                              AS total_cities,
    COUNT(DISTINCT store_id)                                               AS total_stores,

    -- Data freshness
    MIN(observed_at)                                                       AS first_observation_at,
    MAX(observed_at)                                                       AS last_observation_at,
    COUNT(DISTINCT obs_date)                                               AS active_days,

    -- Availability (observations only)
    COUNT(*) FILTER (WHERE source_type = 'observation')                    AS total_obs,
    COUNT(*) FILTER (WHERE source_type = 'observation' AND availability = true)
                                                                           AS available_obs,
    ROUND(100.0
        * COUNT(*) FILTER (WHERE source_type = 'observation' AND availability = true)
        / NULLIF(COUNT(*) FILTER (WHERE source_type = 'observation'), 0), 2)
                                                                           AS overall_osa_pct,

    -- Pricing
    ROUND(AVG(mrp)        FILTER (WHERE source_type = 'observation')::numeric, 2)
                                                                           AS avg_mrp,
    ROUND(AVG(sale_price) FILTER (WHERE source_type = 'observation')::numeric, 2)
                                                                           AS avg_sp,
    ROUND(AVG(
        CASE WHEN mrp > 0 AND sale_price IS NOT NULL
             THEN (mrp - sale_price) / mrp * 100
             ELSE NULL END
    ) FILTER (WHERE source_type = 'observation')::numeric, 2)              AS avg_discount_pct,

    -- Shelf
    COUNT(*) FILTER (WHERE source_type = 'shelf_position')                 AS total_shelf_obs,
    ROUND(100.0
        * COUNT(*) FILTER (WHERE source_type = 'shelf_position' AND is_ad = true)
        / NULLIF(COUNT(*) FILTER (WHERE source_type = 'shelf_position'), 0), 2)
                                                                           AS ad_share_pct,
    ROUND(AVG(position) FILTER (WHERE source_type = 'shelf_position')::numeric, 1)
                                                                           AS avg_shelf_position,

    -- Inventory
    SUM(inventory) FILTER (WHERE source_type = 'observation')              AS total_fe_inventory

FROM gold._base_silver
GROUP BY platform
WITH DATA;

CREATE INDEX ix_mv_platform_overview_platform ON gold.mv_platform_overview (platform);

COMMENT ON MATERIALIZED VIEW gold.mv_platform_overview IS
    'One-row-per-platform summary KPIs for the Overview and Platform dashboards. '
    'Refresh with: REFRESH MATERIALIZED VIEW gold.mv_platform_overview;';


-- ---------------------------------------------------------------------------
-- B. GLOBAL KPI SUMMARY — single-row aggregate across all platforms
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS gold.v_global_kpi CASCADE;

CREATE OR REPLACE VIEW gold.v_global_kpi AS
SELECT
    -- Assortment
    COUNT(DISTINCT effective_sku_key)                                      AS total_skus,
    COUNT(DISTINCT brand)                                                  AS total_brands,
    COUNT(DISTINCT platform)                                               AS total_platforms,
    COUNT(DISTINCT city_slug)                                              AS total_cities,
    COUNT(DISTINCT store_id)                                               AS total_stores,

    -- Data freshness
    MAX(observed_at)                                                       AS data_as_of,
    COUNT(DISTINCT obs_date)                                               AS total_active_days,

    -- Overall OSA (weighted: total available / total eligible)
    ROUND(100.0
        * COUNT(*) FILTER (WHERE source_type = 'observation' AND availability = true)
        / NULLIF(COUNT(*) FILTER (WHERE source_type = 'observation'), 0), 2)
                                                                           AS global_osa_pct,

    -- Average selling price
    ROUND(AVG(sale_price) FILTER (WHERE source_type = 'observation')::numeric, 2)
                                                                           AS global_avg_sp,

    -- Average discount %
    ROUND(AVG(
        CASE WHEN mrp > 0 AND sale_price IS NOT NULL
             THEN (mrp - sale_price) / mrp * 100
             ELSE NULL END
    ) FILTER (WHERE source_type = 'observation')::numeric, 2)              AS global_avg_discount_pct,

    -- Total observations
    COUNT(*) FILTER (WHERE source_type = 'observation')                    AS total_obs,
    COUNT(*) FILTER (WHERE source_type = 'shelf_position')                 AS total_shelf_obs,

    -- NOT AVAILABLE metrics (documented here for dashboard display)
    NULL::numeric   AS sales_value_at_mrp,     -- requires transaction quantities
    NULL::numeric   AS market_share_pct,        -- requires sales data
    NULL::integer   AS po_count,                -- no PO tables found
    NULL::integer   AS critical_sku_count       -- pending business rule definition

FROM gold._base_silver;

COMMENT ON VIEW gold.v_global_kpi IS
    'Single-row global KPI summary across all platforms and dates. '
    'Computed live from gold._base_silver (not materialized). '
    'NULL fields document unavailable metrics — not data errors.';


-- ---------------------------------------------------------------------------
-- C. TOP-10 BRANDS BY OSA (current state)
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS gold.v_top_brands_by_osa CASCADE;

CREATE OR REPLACE VIEW gold.v_top_brands_by_osa AS
SELECT
    platform,
    brand,
    COUNT(DISTINCT effective_sku_key)                        AS skus,
    COUNT(*) FILTER (WHERE source_type = 'observation')      AS total_obs,
    ROUND(100.0
        * COUNT(*) FILTER (WHERE source_type = 'observation' AND availability = true)
        / NULLIF(COUNT(*) FILTER (WHERE source_type = 'observation'), 0), 2)
                                                             AS osa_pct,
    ROUND(AVG(sale_price) FILTER (WHERE source_type = 'observation')::numeric, 2)
                                                             AS avg_sp,
    RANK() OVER (PARTITION BY platform ORDER BY
        COUNT(*) FILTER (WHERE source_type = 'observation' AND availability = true)::float
        / NULLIF(COUNT(*) FILTER (WHERE source_type = 'observation'), 0) DESC)
                                                             AS osa_rank
FROM gold._base_silver
WHERE brand IS NOT NULL
GROUP BY platform, brand;

COMMENT ON VIEW gold.v_top_brands_by_osa IS
    'All brands ranked by OSA per platform. Use with LIMIT 10 for top-10.';


-- ---------------------------------------------------------------------------
-- D. DAILY TREND — platform-level daily rollup for trend charts
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS gold.mv_daily_trend CASCADE;

CREATE MATERIALIZED VIEW gold.mv_daily_trend AS
SELECT
    obs_date,
    platform,
    COUNT(DISTINCT effective_sku_key)                                     AS distinct_skus,
    COUNT(DISTINCT brand)                                                 AS distinct_brands,
    COUNT(DISTINCT store_id)                                              AS distinct_stores,
    -- OSA
    COUNT(*) FILTER (WHERE source_type = 'observation')                   AS total_obs,
    COUNT(*) FILTER (WHERE source_type = 'observation' AND availability = true)
                                                                          AS available_obs,
    ROUND(100.0
        * COUNT(*) FILTER (WHERE source_type = 'observation' AND availability = true)
        / NULLIF(COUNT(*) FILTER (WHERE source_type = 'observation'), 0), 2)
                                                                          AS osa_pct,
    -- Pricing
    ROUND(AVG(sale_price) FILTER (WHERE source_type = 'observation')::numeric, 2)
                                                                          AS avg_sp,
    ROUND(AVG(
        CASE WHEN mrp > 0 AND sale_price IS NOT NULL
             THEN (mrp - sale_price) / mrp * 100 ELSE NULL END
    ) FILTER (WHERE source_type = 'observation')::numeric, 2)             AS avg_discount_pct,
    -- Shelf
    COUNT(*) FILTER (WHERE source_type = 'shelf_position')                AS shelf_positions,
    ROUND(AVG(position) FILTER (WHERE source_type = 'shelf_position')::numeric, 1)
                                                                          AS avg_position,
    ROUND(100.0
        * COUNT(*) FILTER (WHERE source_type = 'shelf_position' AND is_ad = true)
        / NULLIF(COUNT(*) FILTER (WHERE source_type = 'shelf_position'), 0), 2)
                                                                          AS ad_share_pct
FROM gold._base_silver
GROUP BY obs_date, platform
WITH DATA;

CREATE INDEX ix_mv_daily_trend_date_platform ON gold.mv_daily_trend (obs_date, platform);

COMMENT ON MATERIALIZED VIEW gold.mv_daily_trend IS
    'Platform × date daily trend — feeds all time-series charts. '
    'Refresh with: REFRESH MATERIALIZED VIEW gold.mv_daily_trend;';
