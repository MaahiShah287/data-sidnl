-- =============================================================================
-- File:    gold/010_gold_rca_competitor.sql
-- Purpose: Root Cause Analysis (RCA) for low availability +
--          Competitor / cross-platform analytics.
-- Run as:  postgres (Supabase SQL Editor)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- A. RCA: STOCKOUT SIGNALS WITH CONTEXT
--    For each OOS SKU-store pair: inventory, historical OSA trend, repeated OOS
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS gold.mv_rca_stockout CASCADE;

CREATE MATERIALIZED VIEW gold.mv_rca_stockout AS
WITH oos_current AS (
    -- Latest observation that is OOS
    SELECT DISTINCT ON (platform, effective_sku_key, store_id)
        platform,
        effective_sku_key,
        product_name,
        brand,
        COALESCE(l1_category, 'Unknown') AS l1_category,
        COALESCE(l2_category, 'Unknown') AS l2_category,
        city_slug,
        store_id,
        store_name,
        inventory,
        inventory_capped,
        availability,
        stock_status,
        inventory_status,
        observed_at                       AS last_obs_at
    FROM gold._base_silver
    WHERE source_type = 'observation'
      AND availability IS NOT NULL
    ORDER BY platform, effective_sku_key, store_id, observed_at DESC
),
oos_history AS (
    -- How many days in last 7 was this SKU-store OOS?
    SELECT
        platform,
        effective_sku_key,
        store_id,
        COUNT(DISTINCT obs_date)                                     AS days_observed_7d,
        COUNT(DISTINCT obs_date) FILTER (WHERE availability = false) AS days_oos_7d,
        ROUND(100.0
            * COUNT(*) FILTER (WHERE availability = false)
            / NULLIF(COUNT(*), 0), 2)                                AS oos_rate_7d
    FROM gold._base_silver
    WHERE source_type = 'observation'
      AND obs_date >= CURRENT_DATE - INTERVAL '7 days'
    GROUP BY platform, effective_sku_key, store_id
)
SELECT
    c.platform,
    c.effective_sku_key,
    c.product_name,
    c.brand,
    c.l1_category,
    c.l2_category,
    c.city_slug,
    c.store_id,
    c.store_name,
    c.inventory                           AS current_fe_inventory,
    c.availability                        AS current_availability,
    c.stock_status,
    c.last_obs_at,

    -- History
    h.days_observed_7d,
    h.days_oos_7d,
    h.oos_rate_7d,

    -- RCA signal (rule-based, not ML)
    CASE
        WHEN c.availability = false AND c.inventory IS NOT NULL AND c.inventory = 0
             AND h.oos_rate_7d >= 70
             THEN 'CHRONIC_STOCKOUT'
        WHEN c.availability = false AND c.inventory IS NOT NULL AND c.inventory = 0
             THEN 'STOCKOUT_ZERO_INVENTORY'
        WHEN c.availability = false AND c.inventory IS NOT NULL AND c.inventory > 0
             THEN 'OOS_INVENTORY_DISCREPANCY'  -- has stock but not available
        WHEN c.availability = false AND c.inventory IS NULL
             THEN 'OOS_NO_INVENTORY_DATA'
        WHEN c.availability = true AND c.inventory IS NOT NULL AND c.inventory = 0
             THEN 'AVAILABLE_ZERO_STOCK'       -- listed available but stock=0 (data anomaly)
        ELSE 'IN_STOCK'
    END                                   AS rca_signal,

    -- Business impact indicators (not $ values — no sales data)
    -- NULL::numeric AS estimated_lost_units,  -- requires demand model
    -- NULL::numeric AS psl,                   -- requires SP × demand

    -- Priority context (pending business thresholds)
    NULL::text                            AS priority_flag   -- 'CRITICAL'/'HIGH'/'NORMAL' — pending

FROM oos_current c
LEFT JOIN oos_history h
  ON c.platform = h.platform
 AND c.effective_sku_key = h.effective_sku_key
 AND c.store_id = h.store_id
WITH DATA;

CREATE INDEX ix_mv_rca_stockout_platform ON gold.mv_rca_stockout (platform);
CREATE INDEX ix_mv_rca_stockout_brand    ON gold.mv_rca_stockout (brand);
CREATE INDEX ix_mv_rca_stockout_city     ON gold.mv_rca_stockout (city_slug);
CREATE INDEX ix_mv_rca_stockout_signal   ON gold.mv_rca_stockout (rca_signal);

COMMENT ON MATERIALIZED VIEW gold.mv_rca_stockout IS
    'Root cause analysis signals for OOS SKU-store pairs. '
    'rca_signal is rule-based from inventory and historical OOS rate. '
    'PSL/estimated_lost_units require a demand model — marked pending. '
    'Refresh with: REFRESH MATERIALIZED VIEW gold.mv_rca_stockout;';


-- ---------------------------------------------------------------------------
-- B. REPEATED STOCKOUT TREND — which SKUs/brands have chronic OOS?
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS gold.v_rca_chronic_oos CASCADE;

CREATE OR REPLACE VIEW gold.v_rca_chronic_oos AS
SELECT
    platform,
    brand,
    effective_sku_key,
    product_name,
    l1_category,
    l2_category,
    city_slug,
    COUNT(DISTINCT store_id)                                         AS oos_store_count,
    COUNT(*) FILTER (WHERE rca_signal IN ('CHRONIC_STOCKOUT','STOCKOUT_ZERO_INVENTORY'))
                                                                     AS chronic_oos_stores,
    ROUND(AVG(days_oos_7d)::numeric, 1)                              AS avg_days_oos_7d,
    ROUND(AVG(oos_rate_7d)::numeric, 1)                              AS avg_oos_rate_7d
FROM gold.mv_rca_stockout
WHERE rca_signal != 'IN_STOCK'
GROUP BY platform, brand, effective_sku_key, product_name, l1_category, l2_category, city_slug
ORDER BY chronic_oos_stores DESC, avg_oos_rate_7d DESC;

COMMENT ON VIEW gold.v_rca_chronic_oos IS
    'SKUs with chronic OOS across stores — ranked by severity. Use in RCA dashboard.';


-- ---------------------------------------------------------------------------
-- C. COMPETITOR METRICS — cross-platform price comparison
--    Already have mv_price_parity — here we add OSA and assortment comparison
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS gold.mv_competitor_comparison CASCADE;

CREATE MATERIALIZED VIEW gold.mv_competitor_comparison AS
WITH platform_sku AS (
    SELECT DISTINCT ON (platform, effective_sku_key)
        platform,
        effective_sku_key,
        product_name,
        brand,
        COALESCE(l1_category, 'Unknown') AS l1_category,
        COALESCE(l2_category, 'Unknown') AS l2_category,
        mrp,
        sale_price,
        CASE WHEN mrp > 0 AND sale_price IS NOT NULL
             THEN ROUND(((mrp - sale_price) / mrp * 100)::numeric, 2)
             ELSE NULL END               AS discount_pct,
        availability,
        city_slug,
        observed_at
    FROM gold._base_silver
    WHERE source_type = 'observation'
      AND mrp IS NOT NULL
    ORDER BY platform, effective_sku_key, observed_at DESC
)
SELECT
    p.effective_sku_key,
    p.product_name,
    p.brand,
    p.l1_category,
    p.l2_category,
    p.city_slug,
    COUNT(DISTINCT p.platform)                             AS platform_count,
    STRING_AGG(DISTINCT p.platform, ', ' ORDER BY p.platform)
                                                           AS platforms,
    -- Pricing spread
    MIN(p.sale_price)                                      AS min_sp,
    MAX(p.sale_price)                                      AS max_sp,
    ROUND((MAX(p.sale_price) - MIN(p.sale_price))::numeric, 2)
                                                           AS price_gap,
    ROUND(AVG(p.sale_price)::numeric, 2)                   AS avg_sp,
    MIN(p.discount_pct)                                    AS min_discount_pct,
    MAX(p.discount_pct)                                    AS max_discount_pct,
    -- Which platform is cheapest
    (SELECT px.platform FROM platform_sku px
     WHERE px.effective_sku_key = p.effective_sku_key
       AND px.city_slug = p.city_slug
       AND px.sale_price = MIN(p.sale_price)
     LIMIT 1)                                              AS cheapest_platform,
    -- Availability across platforms
    COUNT(DISTINCT p.platform) FILTER (WHERE p.availability = true)
                                                           AS available_on_platforms,
    COUNT(DISTINCT p.platform) FILTER (WHERE p.availability = false)
                                                           AS oos_on_platforms

FROM platform_sku p
GROUP BY p.effective_sku_key, p.product_name, p.brand,
         p.l1_category, p.l2_category, p.city_slug
HAVING COUNT(DISTINCT p.platform) > 1
WITH DATA;

CREATE INDEX ix_mv_competitor_sku    ON gold.mv_competitor_comparison (effective_sku_key);
CREATE INDEX ix_mv_competitor_brand  ON gold.mv_competitor_comparison (brand);
CREATE INDEX ix_mv_competitor_city   ON gold.mv_competitor_comparison (city_slug);

COMMENT ON MATERIALIZED VIEW gold.mv_competitor_comparison IS
    'Cross-platform competitor comparison for SKUs on 2+ platforms: '
    'pricing gap, cheapest platform, OSA per platform. '
    'Refresh with: REFRESH MATERIALIZED VIEW gold.mv_competitor_comparison;';
