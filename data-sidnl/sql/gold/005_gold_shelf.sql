-- =============================================================================
-- File:    gold/005_gold_shelf.sql
-- Purpose: Shelf analytics — position, organic position, ad share.
-- Grain:   shelf_position rows (source_type='shelf_position').
-- Run as:  postgres (Supabase SQL Editor)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- A. CURRENT SHELF POSITION — latest snapshot per SKU × platform × store
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS gold.v_shelf_current CASCADE;

CREATE OR REPLACE VIEW gold.v_shelf_current AS
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
    position,
    organic_position,
    is_ad,
    ad_type,
    product_type,
    mrp,
    sale_price,
    availability,
    observed_at
FROM gold._base_silver
WHERE source_type = 'shelf_position'
ORDER BY platform, effective_sku_key, store_id, observed_at DESC;

COMMENT ON VIEW gold.v_shelf_current IS
    'Latest shelf position per (platform, SKU, store). '
    'Use for real-time visibility / share-of-shelf snapshots.';


-- ---------------------------------------------------------------------------
-- B. SHELF ANALYTICS — daily aggregated metrics per platform × category × city
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS gold.mv_shelf_daily CASCADE;

CREATE MATERIALIZED VIEW gold.mv_shelf_daily AS
SELECT
    obs_date,
    platform,
    brand,
    COALESCE(l1_category, 'Unknown') AS l1_category,
    COALESCE(l2_category, 'Unknown') AS l2_category,
    l3_category,
    city_slug,
    store_id,

    -- Volume
    COUNT(*)                                                       AS total_shelf_positions,

    -- Position stats (lower = better; NULL if no data)
    ROUND(AVG(position)::numeric, 1)                               AS avg_position,
    ROUND(AVG(organic_position)::numeric, 1)                       AS avg_organic_position,
    MIN(position)                                                  AS best_position,
    MIN(organic_position)                                          AS best_organic_position,

    -- Ad metrics
    COUNT(*) FILTER (WHERE is_ad = true)                           AS ad_count,
    COUNT(*) FILTER (WHERE is_ad = false)                          AS organic_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_ad = true)
              / NULLIF(COUNT(*), 0), 2)                            AS ad_share_pct,

    -- Distinct SKUs and brands appearing on shelf
    COUNT(DISTINCT effective_sku_key)                              AS distinct_skus,
    COUNT(DISTINCT brand)                                          AS distinct_brands,

    -- Availability rate on shelf (some shelf items are OOS)
    COUNT(*) FILTER (WHERE availability = true)                    AS available_on_shelf,
    ROUND(100.0 * COUNT(*) FILTER (WHERE availability = true)
              / NULLIF(COUNT(*), 0), 2)                            AS shelf_availability_pct

FROM gold._base_silver
WHERE source_type = 'shelf_position'
GROUP BY obs_date, platform, brand, l1_category, l2_category, l3_category, city_slug, store_id
WITH DATA;

CREATE INDEX ix_mv_shelf_daily_date_platform  ON gold.mv_shelf_daily (obs_date, platform);
CREATE INDEX ix_mv_shelf_daily_brand          ON gold.mv_shelf_daily (brand);
CREATE INDEX ix_mv_shelf_daily_city           ON gold.mv_shelf_daily (city_slug);
CREATE INDEX ix_mv_shelf_daily_l1             ON gold.mv_shelf_daily (l1_category);

COMMENT ON MATERIALIZED VIEW gold.mv_shelf_daily IS
    'Daily shelf analytics (position, ad share, availability) at '
    'platform × brand × category × city × store grain. '
    'Refresh with: REFRESH MATERIALIZED VIEW gold.mv_shelf_daily;';


-- ---------------------------------------------------------------------------
-- C. BRAND SHARE OF SHELF — brand visibility vs total shelf in same category
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS gold.v_brand_shelf_share CASCADE;

CREATE OR REPLACE VIEW gold.v_brand_shelf_share AS
WITH totals AS (
    SELECT
        obs_date,
        platform,
        l1_category,
        l2_category,
        city_slug,
        SUM(total_shelf_positions)   AS category_total_positions,
        SUM(ad_count)                AS category_ad_positions,
        SUM(organic_count)           AS category_organic_positions
    FROM gold.mv_shelf_daily
    GROUP BY obs_date, platform, l1_category, l2_category, city_slug
)
SELECT
    s.obs_date,
    s.platform,
    s.brand,
    s.l1_category,
    s.l2_category,
    s.city_slug,
    SUM(s.total_shelf_positions)                            AS brand_positions,
    t.category_total_positions,
    ROUND(100.0 * SUM(s.total_shelf_positions)
              / NULLIF(t.category_total_positions, 0), 2)   AS sos_pct,
    SUM(s.ad_count)                                         AS brand_ad_positions,
    ROUND(100.0 * SUM(s.ad_count)
              / NULLIF(t.category_ad_positions, 0), 2)      AS ad_sos_pct,
    ROUND(AVG(s.avg_position)::numeric, 1)                  AS avg_position
FROM gold.mv_shelf_daily s
JOIN totals t
  ON s.obs_date = t.obs_date
 AND s.platform = t.platform
 AND s.l1_category = t.l1_category
 AND s.l2_category = t.l2_category
 AND s.city_slug = t.city_slug
GROUP BY s.obs_date, s.platform, s.brand, s.l1_category, s.l2_category,
         s.city_slug, t.category_total_positions, t.category_ad_positions,
         t.category_organic_positions;

COMMENT ON VIEW gold.v_brand_shelf_share IS
    'Brand Share-of-Shelf (SOS) % within each platform × category × city × date. '
    'SOS = brand positions / total category positions × 100.';
