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
