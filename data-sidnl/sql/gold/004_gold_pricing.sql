-- =============================================================================
-- File:    gold/004_gold_pricing.sql
-- Purpose: Pricing metrics — MRP, SP, discount, price parity across platforms.
-- Grain:   observation rows (source_type='observation').
-- Note:    No sales quantities → no Sales Value at MRP, no Weighted Discount.
--          Discount % IS computable from observed MRP vs SP.
-- Run as:  postgres (Supabase SQL Editor)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- A. CURRENT PRICE SNAPSHOT — latest price per SKU × platform × store
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS gold.v_price_current CASCADE;

CREATE OR REPLACE VIEW gold.v_price_current AS
SELECT DISTINCT ON (platform, effective_sku_key, store_id)
    platform,
    effective_sku_key,
    product_name,
    brand,
    l1_category,
    l2_category,
    l3_category,
    city_slug,
    store_id,
    store_name,
    mrp,
    sale_price,
    -- Authoritative computed discount (not from source field)
    CASE
        WHEN mrp IS NOT NULL AND mrp > 0 AND sale_price IS NOT NULL
        THEN ROUND(((mrp - sale_price) / mrp * 100)::numeric, 2)
        ELSE NULL
    END                               AS discount_pct,
    CASE
        WHEN mrp IS NOT NULL AND sale_price IS NOT NULL
        THEN ROUND((mrp - sale_price)::numeric, 2)
        ELSE NULL
    END                               AS discount_amount,
    price_per_unit,
    currency,
    availability,
    observed_at
FROM gold._base_silver
WHERE source_type = 'observation'
  AND mrp IS NOT NULL
ORDER BY platform, effective_sku_key, store_id, observed_at DESC;

COMMENT ON VIEW gold.v_price_current IS
    'Latest observed price (MRP, SP, discount) per (platform, SKU, store). '
    'Discount is computed from MRP and SP — not the source discount_pct field.';


-- ---------------------------------------------------------------------------
-- B. PRICING AGGREGATES — daily summary per platform × brand × category × city
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS gold.mv_pricing_daily CASCADE;

CREATE MATERIALIZED VIEW gold.mv_pricing_daily AS
SELECT
    obs_date,
    platform,
    brand,
    COALESCE(l1_category, 'Unknown') AS l1_category,
    COALESCE(l2_category, 'Unknown') AS l2_category,
    l3_category,
    city_slug,
    COUNT(*)                          AS obs_count,

    -- Average selling price (SP) across all observations in this grain
    ROUND(AVG(sale_price)::numeric, 2)                AS avg_sp,

    -- Average MRP
    ROUND(AVG(mrp)::numeric, 2)                       AS avg_mrp,

    -- Min / max SP (spread within grain)
    ROUND(MIN(sale_price)::numeric, 2)                AS min_sp,
    ROUND(MAX(sale_price)::numeric, 2)                AS max_sp,

    -- Average discount %  (simple mean across individual obs)
    ROUND(AVG(
        CASE WHEN mrp > 0 AND sale_price IS NOT NULL
             THEN (mrp - sale_price) / mrp * 100
             ELSE NULL END
    )::numeric, 2)                                     AS avg_discount_pct,

    -- Max discount %
    ROUND(MAX(
        CASE WHEN mrp > 0 AND sale_price IS NOT NULL
             THEN (mrp - sale_price) / mrp * 100
             ELSE NULL END
    )::numeric, 2)                                     AS max_discount_pct,

    -- Distinct SKUs with discounts
    COUNT(DISTINCT effective_sku_key) FILTER (
        WHERE mrp IS NOT NULL AND mrp > 0
          AND sale_price IS NOT NULL AND sale_price < mrp
    )                                                  AS discounted_skus,

    COUNT(DISTINCT effective_sku_key)                  AS total_skus

FROM gold._base_silver
WHERE source_type = 'observation'
  AND mrp IS NOT NULL AND mrp > 0
GROUP BY obs_date, platform, brand, l1_category, l2_category, l3_category, city_slug
WITH DATA;

CREATE INDEX ix_mv_pricing_daily_date_platform ON gold.mv_pricing_daily (obs_date, platform);
CREATE INDEX ix_mv_pricing_daily_brand          ON gold.mv_pricing_daily (brand);
CREATE INDEX ix_mv_pricing_daily_city           ON gold.mv_pricing_daily (city_slug);

COMMENT ON MATERIALIZED VIEW gold.mv_pricing_daily IS
    'Daily pricing summary at platform × brand × category × city grain. '
    'Refresh with: REFRESH MATERIALIZED VIEW gold.mv_pricing_daily;';


-- ---------------------------------------------------------------------------
-- C. PRICE PARITY — same SKU across different platforms (competitor intelligence)
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS gold.mv_price_parity CASCADE;

CREATE MATERIALIZED VIEW gold.mv_price_parity AS
WITH latest_by_sku AS (
    -- One row per (platform, effective_sku_key) — most recent price
    SELECT DISTINCT ON (platform, effective_sku_key)
        platform,
        effective_sku_key,
        product_name,
        brand,
        l1_category,
        l2_category,
        mrp,
        sale_price,
        city_slug,
        observed_at
    FROM gold._base_silver
    WHERE source_type = 'observation'
      AND mrp IS NOT NULL
    ORDER BY platform, effective_sku_key, observed_at DESC
)
SELECT
    effective_sku_key,
    product_name,
    brand,
    l1_category,
    l2_category,
    city_slug,

    -- Min SP across platforms (best price available)
    MIN(sale_price)                   AS min_sp_cross_platform,
    MAX(sale_price)                   AS max_sp_cross_platform,

    -- Price spread (useful for parity analysis)
    ROUND((MAX(sale_price) - MIN(sale_price))::numeric, 2)
                                      AS sp_spread,

    -- How many platforms list this SKU
    COUNT(DISTINCT platform)          AS platform_count,
    STRING_AGG(DISTINCT platform, ', ' ORDER BY platform)
                                      AS platforms,

    -- Platform with lowest price
    MIN(platform) FILTER (WHERE sale_price = (SELECT MIN(sale_price) FROM latest_by_sku lx WHERE lx.effective_sku_key = l.effective_sku_key))
                                      AS cheapest_platform

FROM latest_by_sku l
GROUP BY effective_sku_key, product_name, brand, l1_category, l2_category, city_slug
HAVING COUNT(DISTINCT platform) > 1
WITH DATA;

CREATE INDEX ix_mv_price_parity_sku  ON gold.mv_price_parity (effective_sku_key);
CREATE INDEX ix_mv_price_parity_brand ON gold.mv_price_parity (brand);

COMMENT ON MATERIALIZED VIEW gold.mv_price_parity IS
    'Cross-platform price comparison for SKUs listed on more than one platform. '
    'Only includes SKUs with platform_count > 1.';
