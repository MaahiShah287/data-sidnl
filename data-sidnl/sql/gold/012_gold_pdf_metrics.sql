-- =============================================================================
-- File:    gold/012_gold_pdf_metrics.sql
-- Purpose: Gold views for metrics from the Business Analytics Metrics & Formulas
--          reference (PDF) not yet covered by 001-011.
--          Sections not applicable to silver data (no sales/quantity, no
--          purchase orders, no GRN/invoices, no keyword search volume):
--            1.x quantity-dependent metrics (Sales value, market share,
--                weighted discount, brand contribution) -> N/A
--            3 DRR/DOI/BE inventory/days-to-expiry -> N/A (already NULL in
--                gold.v_inventory_current)
--            4/6 PO / GRN / Invoice / DN -> not in source data
--            5 Estimated lost units/PSL -> proxied below via stockout × SP
--            8 KW VOL -> source metric, not available in silver
-- Run as:  postgres (Supabase SQL Editor)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- A. PRICE PARITY % — §9: price difference / difference % / threshold
--    Reference platform = cheapest platform for that SKU (lowest latest SP).
--    Reference SP must be > 0 (zero-denominator rule -> NULL).
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS gold.mv_price_parity_pct CASCADE;

CREATE MATERIALIZED VIEW gold.mv_price_parity_pct AS
WITH latest AS (
    SELECT DISTINCT ON (platform, effective_sku_key)
        platform, effective_sku_key, product_name, brand,
        l1_category, l2_category, city_slug, mrp, sale_price
    FROM gold._base_silver
    WHERE source_type = 'observation'
      AND mrp IS NOT NULL AND mrp > 0
      AND sale_price IS NOT NULL
    ORDER BY platform, effective_sku_key, observed_at DESC
),
ref AS (
    -- Reference SP per SKU × city: lowest SP across platforms
    SELECT effective_sku_key, city_slug, MIN(sale_price) AS ref_sp
    FROM latest
    GROUP BY effective_sku_key, city_slug
)
SELECT
    p.platform,
    p.effective_sku_key,
    p.product_name,
    p.brand,
    p.l1_category,
    p.l2_category,
    p.city_slug,
    p.mrp,
    p.sale_price                                             AS sp,
    p.sale_price - r.ref_sp                                  AS price_difference,
    ROUND(100.0 * (p.sale_price - r.ref_sp) / NULLIF(r.ref_sp, 0), 2)
                                                             AS price_difference_pct,
    r.ref_sp                                                 AS reference_sp,
    -- Reference platform = the one charging ref_sp
    (SELECT platform FROM latest lp
      WHERE lp.effective_sku_key = p.effective_sku_key
        AND lp.city_slug     = p.city_slug
      ORDER BY lp.sale_price ASC LIMIT 1)                    AS reference_platform,
    -- Threshold rule: platform SP > reference SP × 1.05 → above threshold
    CASE WHEN p.sale_price > r.ref_sp * 1.05 THEN TRUE ELSE FALSE END
                                                             AS above_5pct_threshold
FROM latest p
JOIN ref r
  ON r.effective_sku_key = p.effective_sku_key
 AND r.city_slug        = p.city_slug
WHERE (SELECT COUNT(DISTINCT platform) FROM latest lp
        WHERE lp.effective_sku_key = p.effective_sku_key
          AND lp.city_slug = p.city_slug) > 1
WITH DATA;

CREATE INDEX ix_mv_ppp_sku    ON gold.mv_price_parity_pct (effective_sku_key);
CREATE INDEX ix_mv_ppp_brand  ON gold.mv_price_parity_pct (brand);
CREATE INDEX ix_mv_ppp_platform ON gold.mv_price_parity_pct (platform);

COMMENT ON MATERIALIZED VIEW gold.mv_price_parity_pct IS
    '§9 Price parity: Platform SP vs reference (cheapest) platform SP. '
    'price_difference, price_difference_pct, 5% threshold flag.';

-- ---------------------------------------------------------------------------
-- B. VISIBILITY SOV — §8: Overall / Organic / Paid SOV %
--    Impression proxy: shelf_position rows (1 shelf appearance = 1 impression).
--    Organic SOV uses organic impressions only; Paid SOV paid only.
--    Note: denominators differ — organic + paid does NOT equal overall.
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS gold.mv_visibility_sov CASCADE;

CREATE MATERIALIZED VIEW gold.mv_visibility_sov AS
SELECT
    obs_date,
    platform,
    brand,
    COUNT(*) FILTER (WHERE is_ad = false)                    AS brand_organic_impressions,
    COUNT(*) FILTER (WHERE is_ad = true)                     AS brand_paid_impressions,
    COUNT(*)                                                 AS brand_total_impressions
FROM gold._base_silver
WHERE source_type = 'shelf_position'
GROUP BY obs_date, platform, brand
WITH DATA;

CREATE INDEX ix_mv_sov_date_platform ON gold.mv_visibility_sov (obs_date, platform);
CREATE INDEX ix_mv_sov_brand         ON gold.mv_visibility_sov (brand);

COMMENT ON MATERIALIZED VIEW gold.mv_visibility_sov IS
    '§8 raw impression counts per brand × platform × date (shelf proxy). '
    'Use v_visibility_sov_pct for the SOV percentages.';

DROP VIEW IF EXISTS gold.v_visibility_sov_pct CASCADE;

CREATE OR REPLACE VIEW gold.v_visibility_sov_pct AS
SELECT
    brand,
    platform,
    SUM(brand_organic_impressions)                           AS organic_impressions,
    SUM(brand_paid_impressions)                              AS paid_impressions,
    -- Organic SOV over the same platform × date market denominator
    ROUND(100.0 * SUM(brand_organic_impressions)
          / NULLIF(SUM(SUM(brand_organic_impressions)) OVER (PARTITION BY platform), 0), 2)
                                                             AS organic_sov_pct,
    ROUND(100.0 * SUM(brand_paid_impressions)
          / NULLIF(SUM(SUM(brand_paid_impressions)) OVER (PARTITION BY platform), 0), 2)
                                                             AS paid_sov_pct,
    ROUND(100.0 * SUM(brand_total_impressions)
          / NULLIF(SUM(SUM(brand_total_impressions)) OVER (PARTITION BY platform), 0), 2)
                                                             AS overall_sov_pct
FROM gold.mv_visibility_sov
GROUP BY brand, platform;

COMMENT ON VIEW gold.v_visibility_sov_pct IS
    '§8 Share of Voice: Overall / Organic / Paid SOV % per brand × platform, '
    'all dates combined. Top-of-search split not available (no position-'
    'zone source field) — avg_organic_position in mv_shelf_daily is a proxy.';

-- ---------------------------------------------------------------------------
-- C. AVG OSA per period — §2: "Average OSA % = average of daily OSA percentages"
--    7-day rolling window ending at each date, per platform × city.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS gold.v_osa_period_avg CASCADE;

CREATE OR REPLACE VIEW gold.v_osa_period_avg AS
WITH daily AS (
    SELECT
        platform, city_slug, obs_date,
        SUM(total_obs)     AS total_obs,
        SUM(available_obs) AS available_obs
    FROM gold.mv_osa_daily
    GROUP BY platform, city_slug, obs_date
),
daily_rate AS (
    SELECT *,
        CASE WHEN total_obs > 0
             THEN 100.0 * available_obs / total_obs END AS daily_osa_pct
    FROM daily
)
SELECT
    t.platform,
    t.city_slug,
    t.obs_date,
    -- 7-day average of daily OSA rates
    ROUND(AVG(t.daily_osa_pct) OVER (
        PARTITION BY t.platform, t.city_slug
        ORDER BY t.obs_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2)       AS avg_osa_7d_pct,
    -- All-time average of daily OSA rates
    ROUND(AVG(t.daily_osa_pct) OVER (
        PARTITION BY t.platform, t.city_slug), 2)           AS avg_osa_all_time_pct,
    -- Overall period rate (aggregated): total available ÷ total observations
    ROUND(100.0 * SUM(available_obs) OVER (
        PARTITION BY t.platform, t.city_slug)
        / NULLIF(SUM(total_obs) OVER (PARTITION BY t.platform, t.city_slug), 0), 2)
                                                             AS overall_osa_pct
FROM daily_rate t;

COMMENT ON VIEW gold.v_osa_period_avg IS
    '§2 Average OSA: average of daily OSA percentages (7d rolling + all-time) '
    'plus aggregated overall rate, per platform × city.';

-- ---------------------------------------------------------------------------
-- D. TOP CITIES / TOP SKUS — §8 rankings by metric of choice (OSA here,
--    extendable to anything available in gold).
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS gold.v_top_cities CASCADE;

CREATE OR REPLACE VIEW gold.v_top_cities AS
SELECT
    platform,
    city_slug,
    ROUND(100.0 * COUNT(*) FILTER (WHERE source_type = 'observation' AND availability = true)
          / NULLIF(COUNT(*) FILTER (WHERE source_type = 'observation'), 0), 2)
                                                                  AS osa_pct,
    COUNT(*) FILTER (WHERE source_type = 'observation')           AS total_obs,
    COUNT(DISTINCT CASE
        WHEN source_type = 'observation' THEN effective_sku_key END) AS distinct_skus,
    ROUND(AVG(sale_price) FILTER (WHERE source_type = 'observation')::numeric, 2)
                                                                  AS avg_sp,
    RANK() OVER (PARTITION BY platform ORDER BY
        100.0 * COUNT(*) FILTER (WHERE source_type = 'observation' AND availability = true)
        / NULLIF(COUNT(*) FILTER (WHERE source_type = 'observation'), 0) DESC) AS rank_by_osa
FROM gold._base_silver
WHERE source_type IN ('observation', 'shelf_position')
GROUP BY platform, city_slug;

COMMENT ON VIEW gold.v_top_cities IS
    '§8 Top cities ranked by OSA per platform (all dates combined).';

DROP VIEW IF EXISTS gold.v_top_skus CASCADE;

CREATE OR REPLACE VIEW gold.v_top_skus AS
SELECT
    platform,
    effective_sku_key,
    MAX(product_name)                                          AS product_name,
    MAX(brand)                                                 AS brand,
    MAX(l1_category)                                           AS l1_category,
    COUNT(*) FILTER (WHERE source_type = 'observation' AND availability = true)
                                                               AS available_obs,
    COUNT(*) FILTER (WHERE source_type = 'observation')         AS total_obs,
    ROUND(100.0 * COUNT(*) FILTER (WHERE source_type = 'observation' AND availability = true)
          / NULLIF(COUNT(*) FILTER (WHERE source_type = 'observation'), 0), 2)
                                                               AS osa_pct,
    ROUND(AVG(sale_price) FILTER (WHERE source_type = 'observation')::numeric, 2)
                                                               AS avg_sp,
    COUNT(*) FILTER (WHERE source_type = 'shelf_position')      AS shelf_appearances,
    ROUND(AVG(organic_position) FILTER (WHERE source_type = 'shelf_position')::numeric, 1)
                                                               AS avg_organic_position,
    RANK() OVER (PARTITION BY platform ORDER BY
        COUNT(*) FILTER (WHERE source_type = 'shelf_position') DESC) AS rank_by_visibility
FROM gold._base_silver
GROUP BY platform, effective_sku_key;

COMMENT ON VIEW gold.v_top_skus IS
    '§8 Top SKUs ranked by shelf visibility (impression proxy) per platform. '
    'Includes OSA and pricing for the selected measure alternatives.';

-- ---------------------------------------------------------------------------
-- E. PSL PROXY — §5: potential sales loss.
--    Expected demand is NOT available (no sales data), so this uses the
--    documented proxy: latest unavailable observation × that SKU's current SP.
--    Business rule: units lost ≈ 1 per store–SKU–date unavailable snapshot.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS gold.v_potential_sales_loss CASCADE;

CREATE OR REPLACE VIEW gold.v_potential_sales_loss AS
WITH latest_obs AS (
    SELECT DISTINCT ON (platform, effective_sku_key, store_id)
        platform, effective_sku_key, store_id, city_slug, brand,
        availability, sale_price
    FROM gold._base_silver
    WHERE source_type = 'observation'
      AND availability IS NOT NULL
    ORDER BY platform, effective_sku_key, store_id, observed_at DESC
)
SELECT
    platform,
    effective_sku_key,
    store_id,
    brand,
    city_slug,
    availability,
    sale_price,
    -- Proxy PSL: unavailable row × SP (1 lost unit per current OOS snapshot)
    CASE WHEN availability = false
         THEN sale_price ELSE NULL
    END                                                        AS psl_proxy
FROM latest_obs
WHERE availability = false;

COMMENT ON VIEW gold.v_potential_sales_loss IS
    '§5 PSL proxy (NOT the PDF formula — expected demand unavailable): '
    'current unavailable store-SKU snapshots × current SP. '
    'True PSL requires Expected/Actual units sold from sales data.';

-- ---------------------------------------------------------------------------
-- F. RCA CHECK SHEET — §7: one row per store-SKU with every RCA input the
--    source data supports (OSA history, FE stock, DRR/DOI/open PO = N/A).
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS gold.v_rca_checks CASCADE;

CREATE OR REPLACE VIEW gold.v_rca_checks AS
WITH obs AS (
    SELECT
        b.platform, b.effective_sku_key, b.store_id,
        MAX(b.product_name)                                  AS product_name,
        MAX(b.brand)                                         AS brand,
        MAX(b.l1_category)                                   AS l1_category,
        MAX(b.city_slug)                                     AS city_slug,
        MAX(s.stock_status)                                  AS latest_stock_status,
        MAX(s.fe_inventory)                                  AS latest_fe_inventory,
        MAX(s.availability::int)::boolean                    AS latest_availability,
        COUNT(DISTINCT b.obs_date)                           AS days_observed,
        COUNT(*)                                             AS total_obs,
        SUM(CASE WHEN b.availability = false THEN 1 ELSE 0 END) AS oos_obs,
        ROUND(100.0 * SUM(CASE WHEN b.availability = true THEN 1 ELSE 0 END)
              / NULLIF(COUNT(*), 0), 2)                      AS osa_pct_current_period
FROM gold._base_silver b
JOIN (
    SELECT DISTINCT ON (platform, effective_sku_key, store_id)
        platform, effective_sku_key, store_id,
        stock_status, inventory AS fe_inventory, availability
    FROM gold._base_silver
    WHERE source_type = 'observation'
    ORDER BY platform, effective_sku_key, store_id, observed_at DESC
) s USING (platform, effective_sku_key, store_id)
GROUP BY b.platform, b.effective_sku_key, b.store_id
)
SELECT
    o.platform,
    o.effective_sku_key,
    o.store_id,
    o.product_name,
    o.brand,
    o.l1_category,
    o.city_slug,
    o.latest_stock_status,
    o.latest_fe_inventory,        -- §7 FE inventory
    NULL::integer                 AS latest_be_inventory,  -- not available
    o.osa_pct_current_period,     -- §7 OSA history aggregated
    o.days_observed,
    o.oos_obs,
    o.total_obs,
    NULL::numeric                 AS drr,        -- no sales data
    NULL::numeric                 AS doi,        -- no sales data
    NULL::integer                 AS open_pos,   -- no PO data
    -- Likely cause (business rule, documented):
    CASE
        WHEN o.latest_fe_inventory = 0        THEN 'FE_STOCK_ZERO'
        WHEN o.latest_availability = false     THEN 'LISTED_UNAVAILABLE'
        WHEN o.osa_pct_current_period < 80.0   THEN 'LOW_OSA_PERIOD'
        ELSE 'OK'
    END                                                        AS likely_cause
FROM obs o;

COMMENT ON VIEW gold.v_rca_checks IS
    '§7 RCA check sheet per store-SKU: OSA history, FE stock, DRR/DOI/open-PO '
    'slots (NULL — unavailable in source) and a rule-based likely_cause.';
