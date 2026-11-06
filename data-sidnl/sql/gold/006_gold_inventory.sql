-- =============================================================================
-- File:    gold/006_gold_inventory.sql
-- Purpose: Inventory / stock health metrics.
-- Note:    - FE inventory = observation.inventory (platform-reported stock count).
--          - BE inventory, unit cost, expiry date: NOT available → metrics marked NULL.
--          - DRR / DOI: NOT computable (no sales quantity data).
--          - Slow-moving / DOI thresholds: NOT set → flagged as pending.
--          - inventory_capped=true means the platform caps the displayed count.
-- Run as:  postgres (Supabase SQL Editor)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- A. CURRENT INVENTORY SNAPSHOT — latest FE inventory per SKU × store
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS gold.v_inventory_current CASCADE;

CREATE OR REPLACE VIEW gold.v_inventory_current AS
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

    -- FE inventory (platform-visible stock)
    inventory                              AS fe_inventory,
    inventory_capped,                      -- true if platform caps the display count

    -- BE inventory: NOT AVAILABLE in source data
    NULL::integer                          AS be_inventory,

    -- Total (FE only since BE = NULL)
    inventory                              AS total_inventory,

    -- DRR / DOI: NOT COMPUTABLE (no sales data)
    NULL::numeric                          AS drr,
    NULL::numeric                          AS doi_fe,
    NULL::numeric                          AS doi_be,
    NULL::numeric                          AS doi_total,

    -- Inventory value: NOT COMPUTABLE (no unit cost)
    NULL::numeric                          AS inventory_value,

    -- Days to expiry: NOT AVAILABLE
    NULL::integer                          AS days_to_expiry,

    availability,
    stock_status,
    inventory_status,
    observed_at

FROM gold._base_silver
WHERE source_type = 'observation'
ORDER BY platform, effective_sku_key, store_id, observed_at DESC;

COMMENT ON VIEW gold.v_inventory_current IS
    'Latest FE (platform-visible) inventory per (platform, SKU, store). '
    'BE inventory, DRR, DOI, inventory value, and days-to-expiry are NULL — '
    'not available in source data.';


-- ---------------------------------------------------------------------------
-- B. DAILY INVENTORY AGGREGATES — per platform × brand × category × city
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS gold.mv_inventory_daily CASCADE;

CREATE MATERIALIZED VIEW gold.mv_inventory_daily AS
SELECT
    obs_date,
    platform,
    brand,
    COALESCE(l1_category, 'Unknown') AS l1_category,
    COALESCE(l2_category, 'Unknown') AS l2_category,
    l3_category,
    city_slug,

    COUNT(*)                                                AS obs_count,
    COUNT(*) FILTER (WHERE inventory IS NOT NULL)           AS obs_with_inventory,

    -- FE inventory stats across stores
    SUM(inventory)                                          AS total_fe_inventory,
    ROUND(AVG(inventory)::numeric, 1)                       AS avg_fe_inventory_per_store,
    MIN(inventory)                                          AS min_fe_inventory,
    MAX(inventory)                                          AS max_fe_inventory,

    -- Inventory capped flag rate
    COUNT(*) FILTER (WHERE inventory_capped = true)         AS capped_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE inventory_capped = true)
              / NULLIF(COUNT(*), 0), 2)                     AS capped_pct,

    -- Stores with zero inventory (OOS by stock count)
    COUNT(*) FILTER (WHERE inventory IS NOT NULL AND inventory = 0)
                                                            AS zero_inventory_stores,

    -- Distinct stores monitored in this grain
    COUNT(DISTINCT store_id)                                AS distinct_stores,
    COUNT(DISTINCT effective_sku_key)                       AS distinct_skus

FROM gold._base_silver
WHERE source_type = 'observation'
GROUP BY obs_date, platform, brand, l1_category, l2_category, l3_category, city_slug
WITH DATA;

CREATE INDEX ix_mv_inventory_daily_date_platform ON gold.mv_inventory_daily (obs_date, platform);
CREATE INDEX ix_mv_inventory_daily_brand         ON gold.mv_inventory_daily (brand);
CREATE INDEX ix_mv_inventory_daily_city          ON gold.mv_inventory_daily (city_slug);

COMMENT ON MATERIALIZED VIEW gold.mv_inventory_daily IS
    'Daily FE inventory aggregates at platform × brand × category × city grain. '
    'DRR, DOI, and inventory value cannot be computed — no sales data in source. '
    'Refresh with: REFRESH MATERIALIZED VIEW gold.mv_inventory_daily;';


-- ---------------------------------------------------------------------------
-- C. STOCKOUT DETECTION VIEW (OOS indicators from observation data)
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS gold.v_stockout_signals CASCADE;

CREATE OR REPLACE VIEW gold.v_stockout_signals AS
SELECT DISTINCT ON (platform, effective_sku_key, store_id)
    platform,
    effective_sku_key,
    product_name,
    brand,
    l1_category,
    l2_category,
    city_slug,
    store_id,
    store_name,
    inventory,
    inventory_capped,
    availability,
    stock_status,
    inventory_status,
    observed_at,

    -- Stockout signal: listed but unavailable OR inventory = 0
    CASE
        WHEN availability = false                        THEN 'OOS_UNAVAILABLE'
        WHEN inventory IS NOT NULL AND inventory = 0     THEN 'OOS_ZERO_STOCK'
        WHEN availability = true AND inventory IS NOT NULL
             AND inventory > 0                           THEN 'IN_STOCK'
        WHEN availability = true AND inventory IS NULL   THEN 'LISTED_NO_STOCK_DATA'
        ELSE 'UNKNOWN'
    END                                                  AS oos_signal

FROM gold._base_silver
WHERE source_type = 'observation'
ORDER BY platform, effective_sku_key, store_id, observed_at DESC;

COMMENT ON VIEW gold.v_stockout_signals IS
    'OOS signal per (platform, SKU, store) based on latest observation. '
    'Signals: OOS_UNAVAILABLE / OOS_ZERO_STOCK / IN_STOCK / LISTED_NO_STOCK_DATA / UNKNOWN.';
