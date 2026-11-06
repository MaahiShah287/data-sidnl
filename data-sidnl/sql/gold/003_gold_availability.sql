-- =============================================================================
-- File:    gold/003_gold_availability.sql
-- Purpose: OSA (On-Shelf Availability) metrics at multiple grains.
-- Grain:   observation rows from source_type='observation' only.
-- Note:    shelf_position rows are EXCLUDED from availability calc —
--          shelf scrapes do not reliably represent the same coverage as check runs.
-- Run as:  postgres (Supabase SQL Editor)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- A. DAILY OSA BY PLATFORM × BRAND × CATEGORY × CITY
-- Materialized for query performance. Refresh after each data load.
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS gold.mv_osa_daily CASCADE;

CREATE MATERIALIZED VIEW gold.mv_osa_daily AS
WITH obs AS (
    SELECT
        obs_date,
        platform,
        brand,
        COALESCE(l1_category, 'Unknown') AS l1_category,
        COALESCE(l2_category, 'Unknown') AS l2_category,
        l3_category,                          -- intentionally NULL when missing
        city_slug,
        store_id,
        effective_sku_key,
        availability
    FROM gold._base_silver
    WHERE source_type = 'observation'
      AND availability IS NOT NULL
)
SELECT
    obs_date,
    platform,
    brand,
    l1_category,
    l2_category,
    l3_category,
    city_slug,

    -- Total observations in this grain
    COUNT(*)                                                      AS total_obs,
    COUNT(*) FILTER (WHERE availability = true)                   AS available_obs,
    COUNT(*) FILTER (WHERE availability = false)                  AS unavailable_obs,

    -- OSA %  = available / total × 100 (NULL-safe: returns NULL if 0 total)
    CASE
        WHEN COUNT(*) > 0
        THEN ROUND(100.0 * COUNT(*) FILTER (WHERE availability = true) / COUNT(*), 2)
        ELSE NULL
    END                                                           AS osa_pct,

    -- Distinct stores and SKUs in this grain
    COUNT(DISTINCT store_id)                                      AS distinct_stores,
    COUNT(DISTINCT effective_sku_key)                             AS distinct_skus

FROM obs
GROUP BY obs_date, platform, brand, l1_category, l2_category, l3_category, city_slug
WITH DATA;

CREATE INDEX ix_mv_osa_daily_date_platform  ON gold.mv_osa_daily (obs_date, platform);
CREATE INDEX ix_mv_osa_daily_brand          ON gold.mv_osa_daily (brand);
CREATE INDEX ix_mv_osa_daily_city           ON gold.mv_osa_daily (city_slug);
CREATE INDEX ix_mv_osa_daily_l1             ON gold.mv_osa_daily (l1_category);

COMMENT ON MATERIALIZED VIEW gold.mv_osa_daily IS
    'Daily OSA % at platform × brand × l1/l2/l3_category × city_slug grain. '
    'Source: source_type=observation only. Refresh with: REFRESH MATERIALIZED VIEW gold.mv_osa_daily;';


-- ---------------------------------------------------------------------------
-- B. OSA D-MINUS SUMMARY (D-1, D-2, D-3 relative to latest available date)
-- A lightweight regular view — always current relative to what''s in the table.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS gold.v_osa_d_minus CASCADE;

CREATE OR REPLACE VIEW gold.v_osa_d_minus AS
WITH latest_date AS (
    SELECT MAX(obs_date) AS ld FROM gold.mv_osa_daily
),
daily_totals AS (
    SELECT
        m.obs_date,
        m.platform,
        m.city_slug,
        SUM(m.total_obs)     AS total_obs,
        SUM(m.available_obs) AS available_obs,
        (SELECT ld FROM latest_date) AS latest_date
    FROM gold.mv_osa_daily m
    GROUP BY m.obs_date, m.platform, m.city_slug
)
SELECT
    platform,
    city_slug,
    latest_date,

    -- D-1
    ROUND(100.0 * SUM(available_obs) FILTER (WHERE obs_date = latest_date)
                 / NULLIF(SUM(total_obs) FILTER (WHERE obs_date = latest_date), 0), 2)
        AS osa_d1_pct,

    -- D-2
    ROUND(100.0 * SUM(available_obs) FILTER (WHERE obs_date = latest_date - INTERVAL '1 day')
                 / NULLIF(SUM(total_obs) FILTER (WHERE obs_date = latest_date - INTERVAL '1 day'), 0), 2)
        AS osa_d2_pct,

    -- D-3
    ROUND(100.0 * SUM(available_obs) FILTER (WHERE obs_date = latest_date - INTERVAL '2 days')
                 / NULLIF(SUM(total_obs) FILTER (WHERE obs_date = latest_date - INTERVAL '2 days'), 0), 2)
        AS osa_d3_pct,

    -- Average OSA across those 3 days (average of daily rates)
    ROUND(AVG(
        CASE WHEN total_obs > 0
             THEN 100.0 * available_obs / total_obs
             ELSE NULL END
    ) FILTER (WHERE obs_date >= latest_date - INTERVAL '2 days'), 2)
        AS osa_avg_3d_pct

FROM daily_totals
GROUP BY platform, city_slug, latest_date;

COMMENT ON VIEW gold.v_osa_d_minus IS
    'OSA for D-1, D-2, D-3 relative to the latest date in mv_osa_daily. '
    'Recalculated on every query — reflects the materialized view''s data freshness.';


-- ---------------------------------------------------------------------------
-- C. OSA CURRENT SNAPSHOT — per SKU × platform × store (latest observation)
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS gold.v_osa_current CASCADE;

CREATE OR REPLACE VIEW gold.v_osa_current AS
SELECT DISTINCT ON (platform, effective_sku_key, store_id)
    platform,
    effective_sku_key,
    product_name,
    brand,
    l1_category,
    l2_category,
    l3_category,
    store_id,
    store_name,
    city_slug,
    availability,
    inventory,
    inventory_capped,
    stock_status,
    inventory_status,
    observed_at
FROM gold._base_silver
WHERE source_type = 'observation'
  AND availability IS NOT NULL
ORDER BY platform, effective_sku_key, store_id, observed_at DESC;

COMMENT ON VIEW gold.v_osa_current IS
    'Latest availability observation per (platform, SKU, store). '
    'Use for real-time OSA dashboard snapshots.';


-- ---------------------------------------------------------------------------
-- D. ASSORTMENT — count of distinct SKUs listed per platform × category × city
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS gold.v_assortment CASCADE;

CREATE OR REPLACE VIEW gold.v_assortment AS
SELECT
    platform,
    COALESCE(l1_category, 'Unknown') AS l1_category,
    COALESCE(l2_category, 'Unknown') AS l2_category,
    l3_category,
    city_slug,

    COUNT(DISTINCT effective_sku_key)                             AS total_skus,
    COUNT(DISTINCT effective_sku_key) FILTER (WHERE availability = true)
                                                                  AS available_skus,
    COUNT(DISTINCT effective_sku_key) FILTER (WHERE availability = false)
                                                                  AS unavailable_skus,

    -- Assortment coverage %: available SKUs / all listed SKUs
    CASE
        WHEN COUNT(DISTINCT effective_sku_key) > 0
        THEN ROUND(100.0
                * COUNT(DISTINCT effective_sku_key) FILTER (WHERE availability = true)
                / COUNT(DISTINCT effective_sku_key), 2)
        ELSE NULL
    END                                                           AS assortment_coverage_pct,

    -- Dark-store listing %: stores listing this SKU / all stores in this grain
    COUNT(DISTINCT store_id)                                      AS stores_seen,
    COUNT(DISTINCT store_id) FILTER (WHERE availability = true)   AS stores_with_availability

FROM gold._base_silver
WHERE source_type = 'observation'
GROUP BY platform, l1_category, l2_category, l3_category, city_slug;

COMMENT ON VIEW gold.v_assortment IS
    'Assortment breadth and coverage per platform × category × city. '
    'Grain: source_type=observation, all dates combined (snapshot view).';
