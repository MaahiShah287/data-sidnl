-- =============================================================================
-- File:    01_views.sql  (Phase 1 — restored after server restart)
-- Purpose: Safe, deduplicated views over the silver layer for the SIDNL chatbot.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- DESIGN DECISIONS
-- ---------------------------------------------------------------------------
-- 1. silver.demo is NEVER included in any view.
-- 2. Explicit column lists (no SELECT *).
-- 3. data_quality_status = 'valid' is the primary quality gate.
-- 4. scrape_status / scrape_run_status filters are marked TODO until confirmed
--    by diagnostics (see sql/02_diagnostics.sql).
-- 5. NULL listing_id fallback: COALESCE(listing_id, platform_product_id).
-- ---------------------------------------------------------------------------

-- =============================================================================
-- VIEW 1: silver.v_all_platforms
-- =============================================================================
DROP VIEW IF EXISTS silver.v_all_platforms CASCADE;

CREATE OR REPLACE VIEW silver.v_all_platforms AS
    SELECT
        id, platform, source_type, source_record_id, listing_id, product_id,
        store_id, run_id, scrape_run_id,
        l1_id, l1_category, l2_id, l2_category, l3_id, l3_category, category_path,
        platform_product_id, sku_code, product_name, sku_name, brand, variant,
        product_description, product_url, image_url, pack_size, pack_unit,
        quantity, quantity_unit,
        mrp, sale_price, discount_amount, discount_percentage, price_per_unit, currency,
        inventory, inventory_capped, available_quantity, availability,
        stock_status, inventory_status, delivery_eta_minutes,
        position, organic_position, is_ad, ad_type, product_type,
        store_external_id, store_name, city, city_slug, state, pincode, latitude, longitude,
        observed_at, scraped_at, transformed_at, source_url, scrape_status, scrape_backend,
        scrape_run_status, data_quality_status, validation_errors, raw_details,
        source_metadata, bronze_record_ids
    FROM silver.blinkit
    WHERE data_quality_status = 'valid'
    -- TODO(diagnostics): AND scrape_status IN ('<confirmed_success_values>')
    -- TODO(diagnostics): AND scrape_run_status IN ('<confirmed_success_values>')

UNION ALL
    SELECT
        id, platform, source_type, source_record_id, listing_id, product_id,
        store_id, run_id, scrape_run_id,
        l1_id, l1_category, l2_id, l2_category, l3_id, l3_category, category_path,
        platform_product_id, sku_code, product_name, sku_name, brand, variant,
        product_description, product_url, image_url, pack_size, pack_unit,
        quantity, quantity_unit,
        mrp, sale_price, discount_amount, discount_percentage, price_per_unit, currency,
        inventory, inventory_capped, available_quantity, availability,
        stock_status, inventory_status, delivery_eta_minutes,
        position, organic_position, is_ad, ad_type, product_type,
        store_external_id, store_name, city, city_slug, state, pincode, latitude, longitude,
        observed_at, scraped_at, transformed_at, source_url, scrape_status, scrape_backend,
        scrape_run_status, data_quality_status, validation_errors, raw_details,
        source_metadata, bronze_record_ids
    FROM silver.zepto
    WHERE data_quality_status = 'valid'
    -- TODO(diagnostics): AND scrape_status IN ('<confirmed_success_values>')
    -- TODO(diagnostics): AND scrape_run_status IN ('<confirmed_success_values>')

UNION ALL
    SELECT
        id, platform, source_type, source_record_id, listing_id, product_id,
        store_id, run_id, scrape_run_id,
        l1_id, l1_category, l2_id, l2_category, l3_id, l3_category, category_path,
        platform_product_id, sku_code, product_name, sku_name, brand, variant,
        product_description, product_url, image_url, pack_size, pack_unit,
        quantity, quantity_unit,
        mrp, sale_price, discount_amount, discount_percentage, price_per_unit, currency,
        inventory, inventory_capped, available_quantity, availability,
        stock_status, inventory_status, delivery_eta_minutes,
        position, organic_position, is_ad, ad_type, product_type,
        store_external_id, store_name, city, city_slug, state, pincode, latitude, longitude,
        observed_at, scraped_at, transformed_at, source_url, scrape_status, scrape_backend,
        scrape_run_status, data_quality_status, validation_errors, raw_details,
        source_metadata, bronze_record_ids
    FROM silver.instamart
    WHERE data_quality_status = 'valid'
    -- TODO(diagnostics): AND scrape_status IN ('<confirmed_success_values>')
    -- TODO(diagnostics): AND scrape_run_status IN ('<confirmed_success_values>')

UNION ALL
    SELECT
        id, platform, source_type, source_record_id, listing_id, product_id,
        store_id, run_id, scrape_run_id,
        l1_id, l1_category, l2_id, l2_category, l3_id, l3_category, category_path,
        platform_product_id, sku_code, product_name, sku_name, brand, variant,
        product_description, product_url, image_url, pack_size, pack_unit,
        quantity, quantity_unit,
        mrp, sale_price, discount_amount, discount_percentage, price_per_unit, currency,
        inventory, inventory_capped, available_quantity, availability,
        stock_status, inventory_status, delivery_eta_minutes,
        position, organic_position, is_ad, ad_type, product_type,
        store_external_id, store_name, city, city_slug, state, pincode, latitude, longitude,
        observed_at, scraped_at, transformed_at, source_url, scrape_status, scrape_backend,
        scrape_run_status, data_quality_status, validation_errors, raw_details,
        source_metadata, bronze_record_ids
    FROM silver.jiomart
    WHERE data_quality_status = 'valid'
    -- TODO(diagnostics): AND scrape_status IN ('<confirmed_success_values>')
    -- TODO(diagnostics): AND scrape_run_status IN ('<confirmed_success_values>')
;

COMMENT ON VIEW silver.v_all_platforms IS
    'UNION ALL of blinkit, zepto, instamart, jiomart filtered to data_quality_status=valid. '
    'silver.demo is EXCLUDED. No deduplication.';

-- =============================================================================
-- VIEW 2: silver.v_latest_observation
-- =============================================================================
DROP VIEW IF EXISTS silver.v_latest_observation CASCADE;

CREATE OR REPLACE VIEW silver.v_latest_observation AS
SELECT DISTINCT ON (platform, COALESCE(listing_id, platform_product_id), store_id)
    COALESCE(listing_id, platform_product_id) AS effective_listing_id,
    id, platform, source_type, source_record_id, listing_id, product_id,
    store_id, run_id, scrape_run_id,
    l1_id, l1_category, l2_id, l2_category, l3_id, l3_category, category_path,
    platform_product_id, sku_code, product_name, sku_name, brand, variant,
    product_description, product_url, image_url, pack_size, pack_unit,
    quantity, quantity_unit,
    mrp, sale_price, discount_amount, discount_percentage, price_per_unit, currency,
    inventory, inventory_capped, available_quantity, availability,
    stock_status, inventory_status, delivery_eta_minutes,
    position, organic_position, is_ad, ad_type, product_type,
    store_external_id, store_name, city, city_slug, state, pincode, latitude, longitude,
    observed_at, scraped_at, transformed_at, source_url, scrape_status, scrape_backend,
    scrape_run_status, data_quality_status, validation_errors, raw_details,
    source_metadata, bronze_record_ids
FROM silver.v_all_platforms
WHERE source_type = 'observation'
ORDER BY platform, COALESCE(listing_id, platform_product_id), store_id, observed_at DESC;

COMMENT ON VIEW silver.v_latest_observation IS
    'One row per (platform, effective_listing_id, store_id) for source_type=observation. '
    'Use for price, availability, stock metrics.';

-- =============================================================================
-- VIEW 3: silver.v_latest_shelf_position
-- =============================================================================
DROP VIEW IF EXISTS silver.v_latest_shelf_position CASCADE;

CREATE OR REPLACE VIEW silver.v_latest_shelf_position AS
SELECT DISTINCT ON (platform, COALESCE(listing_id, platform_product_id), store_id)
    COALESCE(listing_id, platform_product_id) AS effective_listing_id,
    id, platform, source_type, source_record_id, listing_id, product_id,
    store_id, run_id, scrape_run_id,
    l1_id, l1_category, l2_id, l2_category, l3_id, l3_category, category_path,
    platform_product_id, sku_code, product_name, sku_name, brand, variant,
    product_description, product_url, image_url, pack_size, pack_unit,
    quantity, quantity_unit,
    mrp, sale_price, discount_amount, discount_percentage, price_per_unit, currency,
    inventory, inventory_capped, available_quantity, availability,
    stock_status, inventory_status, delivery_eta_minutes,
    position, organic_position, is_ad, ad_type, product_type,
    store_external_id, store_name, city, city_slug, state, pincode, latitude, longitude,
    observed_at, scraped_at, transformed_at, source_url, scrape_status, scrape_backend,
    scrape_run_status, data_quality_status, validation_errors, raw_details,
    source_metadata, bronze_record_ids
FROM silver.v_all_platforms
WHERE source_type = 'shelf_position'
ORDER BY
    platform,
    COALESCE(listing_id, platform_product_id),
    store_id,
    COALESCE(scrape_run_id, '00000000-0000-0000-0000-000000000000'::text) DESC NULLS LAST,
    observed_at DESC;

COMMENT ON VIEW silver.v_latest_shelf_position IS
    'One row per (platform, effective_listing_id, store_id) for source_type=shelf_position. '
    'Use for visibility metrics: position, organic_position, is_ad, ad_type.';
