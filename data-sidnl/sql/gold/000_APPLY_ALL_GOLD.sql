-- =============================================================================
-- SIDNL GOLD LAYER — COMPLETE MIGRATION
-- Run this ONCE in Supabase SQL Editor as postgres (superuser).
-- After running, execute 011_gold_refresh.sql to populate materialized views.
-- Files combined: 001 through 010 (011 is the refresh script, run separately).
-- =============================================================================

-- ============ FROM: 001_gold_schema.sql ============

-- =============================================================================
-- File:    gold/001_gold_schema.sql
-- Purpose: Create the gold schema and grant access to ecomscraper_backend.
-- Run as:  postgres (Supabase SQL Editor)
-- =============================================================================

-- 1. Create the gold schema
CREATE SCHEMA IF NOT EXISTS gold;

-- 2. Grant to the application role
GRANT USAGE ON SCHEMA gold TO ecomscraper_backend;

-- 3. Default privileges so future objects are auto-granted
ALTER DEFAULT PRIVILEGES IN SCHEMA gold
    GRANT SELECT ON TABLES TO ecomscraper_backend;

-- Also ensure silver views are created and accessible
-- (Run 01_views.sql first if not already done)
GRANT USAGE ON SCHEMA silver TO ecomscraper_backend;
ALTER DEFAULT PRIVILEGES IN SCHEMA silver
    GRANT SELECT ON TABLES TO ecomscraper_backend;

COMMENT ON SCHEMA gold IS
    'Business-ready, aggregated analytics datasets. '
    'Built on silver.* (blinkit, zepto, instamart, jiomart). '
    'Created: 2026-11-06. No raw bronze records stored here.';

-- ============ FROM: 002_gold_base_union.sql ============

-- =============================================================================
-- File:    gold/002_gold_base_union.sql
-- Purpose: A single CTE-ready base union view across all silver platforms.
--          Gold views build on silver.v_all_platforms (once 01_views.sql is applied).
--          Until then, this view duplicates the union logic directly from silver tables
--          so the Gold layer can function independently.
-- Run as:  postgres (Supabase SQL Editor)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- DESIGN NOTES
-- ---------------------------------------------------------------------------
-- • Source:  silver.{blinkit, zepto, instamart, jiomart}
-- • Filter:  data_quality_status = 'valid' (the only quality status present)
-- • silver.demo is intentionally excluded (test/demo data)
-- • Both source_types coexist: 'observation' and 'shelf_position'
-- • NULL l1_category values occur in the data — preserved, not coalesced
-- • COALESCE(listing_id::text, platform_product_id) used as effective_sku_key
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS gold._base_silver CASCADE;

CREATE OR REPLACE VIEW gold._base_silver AS
SELECT
    id,
    platform,
    source_type,
    source_record_id,
    COALESCE(listing_id::text, platform_product_id)   AS effective_sku_key,
    listing_id,
    product_id,
    store_id,
    run_id,
    scrape_run_id,

    -- Category hierarchy (NULLs are real data, not errors)
    l1_id,
    NULLIF(TRIM(l1_category), '')                     AS l1_category,
    l2_id,
    NULLIF(TRIM(l2_category), '')                     AS l2_category,
    l3_id,
    NULLIF(TRIM(l3_category), '')                     AS l3_category,
    category_path,

    -- Product identity
    platform_product_id,
    sku_code,
    product_name,
    sku_name,
    brand,
    variant,
    pack_size,
    pack_unit,
    quantity,
    quantity_unit,
    image_url,
    product_url,

    -- Pricing
    mrp::numeric(12,2)              AS mrp,
    sale_price::numeric(12,2)       AS sale_price,
    discount_amount::numeric(12,2)  AS discount_amount,
    discount_percentage::numeric(6,2) AS discount_pct_raw,  -- from source (may differ from computed)
    price_per_unit::numeric(12,4)   AS price_per_unit,
    currency,

    -- Computed discount (authoritative — avoids source rounding issues)
    CASE
        WHEN mrp IS NOT NULL AND mrp > 0 AND sale_price IS NOT NULL
        THEN ROUND(((mrp - sale_price) / mrp * 100)::numeric, 2)
        ELSE NULL
    END                             AS discount_pct,

    -- Availability / Inventory
    inventory,
    inventory_capped,
    available_quantity,
    availability,
    stock_status,
    inventory_status,
    delivery_eta_minutes,

    -- Shelf
    position,
    organic_position,
    is_ad,
    ad_type,
    product_type,

    -- Geography / Store
    store_external_id,
    store_name,
    city,
    city_slug,
    state,
    pincode,
    latitude,
    longitude,

    -- Timestamps
    observed_at,
    scraped_at,
    DATE(observed_at AT TIME ZONE 'Asia/Kolkata') AS obs_date,

    -- Data quality / provenance
    data_quality_status,
    scrape_status,
    scrape_backend

FROM silver.blinkit
WHERE data_quality_status = 'valid'

UNION ALL

SELECT
    id, platform, source_type, source_record_id,
    COALESCE(listing_id::text, platform_product_id),
    listing_id, product_id, store_id, run_id, scrape_run_id,
    l1_id, NULLIF(TRIM(l1_category), ''), l2_id, NULLIF(TRIM(l2_category), ''),
    l3_id, NULLIF(TRIM(l3_category), ''), category_path,
    platform_product_id, sku_code, product_name, sku_name, brand, variant,
    pack_size, pack_unit, quantity, quantity_unit, image_url, product_url,
    mrp::numeric(12,2), sale_price::numeric(12,2), discount_amount::numeric(12,2),
    discount_percentage::numeric(6,2),
    price_per_unit::numeric(12,4), currency,
    CASE WHEN mrp IS NOT NULL AND mrp > 0 AND sale_price IS NOT NULL
         THEN ROUND(((mrp - sale_price) / mrp * 100)::numeric, 2) ELSE NULL END,
    inventory, inventory_capped, available_quantity, availability,
    stock_status, inventory_status, delivery_eta_minutes,
    position, organic_position, is_ad, ad_type, product_type,
    store_external_id, store_name, city, city_slug, state, pincode, latitude, longitude,
    observed_at, scraped_at,
    DATE(observed_at AT TIME ZONE 'Asia/Kolkata'),
    data_quality_status, scrape_status, scrape_backend
FROM silver.zepto
WHERE data_quality_status = 'valid'

UNION ALL

SELECT
    id, platform, source_type, source_record_id,
    COALESCE(listing_id::text, platform_product_id),
    listing_id, product_id, store_id, run_id, scrape_run_id,
    l1_id, NULLIF(TRIM(l1_category), ''), l2_id, NULLIF(TRIM(l2_category), ''),
    l3_id, NULLIF(TRIM(l3_category), ''), category_path,
    platform_product_id, sku_code, product_name, sku_name, brand, variant,
    pack_size, pack_unit, quantity, quantity_unit, image_url, product_url,
    mrp::numeric(12,2), sale_price::numeric(12,2), discount_amount::numeric(12,2),
    discount_percentage::numeric(6,2),
    price_per_unit::numeric(12,4), currency,
    CASE WHEN mrp IS NOT NULL AND mrp > 0 AND sale_price IS NOT NULL
         THEN ROUND(((mrp - sale_price) / mrp * 100)::numeric, 2) ELSE NULL END,
    inventory, inventory_capped, available_quantity, availability,
    stock_status, inventory_status, delivery_eta_minutes,
    position, organic_position, is_ad, ad_type, product_type,
    store_external_id, store_name, city, city_slug, state, pincode, latitude, longitude,
    observed_at, scraped_at,
    DATE(observed_at AT TIME ZONE 'Asia/Kolkata'),
    data_quality_status, scrape_status, scrape_backend
FROM silver.instamart
WHERE data_quality_status = 'valid'

UNION ALL

SELECT
    id, platform, source_type, source_record_id,
    COALESCE(listing_id::text, platform_product_id),
    listing_id, product_id, store_id, run_id, scrape_run_id,
    l1_id, NULLIF(TRIM(l1_category), ''), l2_id, NULLIF(TRIM(l2_category), ''),
    l3_id, NULLIF(TRIM(l3_category), ''), category_path,
    platform_product_id, sku_code, product_name, sku_name, brand, variant,
    pack_size, pack_unit, quantity, quantity_unit, image_url, product_url,
    mrp::numeric(12,2), sale_price::numeric(12,2), discount_amount::numeric(12,2),
    discount_percentage::numeric(6,2),
    price_per_unit::numeric(12,4), currency,
    CASE WHEN mrp IS NOT NULL AND mrp > 0 AND sale_price IS NOT NULL
         THEN ROUND(((mrp - sale_price) / mrp * 100)::numeric, 2) ELSE NULL END,
    inventory, inventory_capped, available_quantity, availability,
    stock_status, inventory_status, delivery_eta_minutes,
    position, organic_position, is_ad, ad_type, product_type,
    store_external_id, store_name, city, city_slug, state, pincode, latitude, longitude,
    observed_at, scraped_at,
    DATE(observed_at AT TIME ZONE 'Asia/Kolkata'),
    data_quality_status, scrape_status, scrape_backend
FROM silver.jiomart
WHERE data_quality_status = 'valid';

COMMENT ON VIEW gold._base_silver IS
    'Internal base union of all silver platform tables (excluding demo). '
    'Filtered to data_quality_status=valid. All gold views derive from this. '
    'Prefix _ means internal — do not expose to API directly.';

-- ============ FROM: 003_gold_availability.sql ============

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

-- ============ FROM: 004_gold_pricing.sql ============

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

-- ============ FROM: 005_gold_shelf.sql ============

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

-- ============ FROM: 006_gold_inventory.sql ============

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

-- ============ FROM: 007_gold_brand_product.sql ============

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

-- ============ FROM: 008_gold_geography_category.sql ============

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

-- ============ FROM: 009_gold_overview.sql ============

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

-- ============ FROM: 010_gold_rca_competitor.sql ============

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
