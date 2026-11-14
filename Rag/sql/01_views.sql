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

-- =============================================================================
-- GOLD (dash) LAYER
-- =============================================================================
-- The Gold layer is built by the pipeline, not by this file: dash.* tables and
-- views are refreshed by silver.run_gold_pending() and are owned by postgres.
-- Nothing below redefines them. We only add ONE chatbot-facing safety view and
-- document the map so the next person knows what is available.
--
-- Run this section on its own (do NOT re-run the Silver section above unless
-- you intend to drop/recreate the Silver views):
--
--     psql "$SUPABASE_DB_URL" -f sql/01_views.sql   -- section only
--
-- -----------------------------------------------------------------------------
-- GOLD MAP (read this before writing SQL)
-- -----------------------------------------------------------------------------
-- Facts, one row per grain:
--   dash.availability      SKU x city x day (obs_date). store_key NULL = city
--                          total; store_key set = one dark store.
--                          >>> NEVER sum both row types together. <<<
--                          osa_pct = osa_available_obs / osa_eligible_obs.
--   dash.pricing           SKU x city x day: mrp, selling_price, discount_pct,
--                          parity vs national / lowest marketplace / reference.
--   dash.visibility        SKU x category shelf or keyword x day: rank,
--                          impressions, share_of_voice_pct.
--   dash.coverage          day x platform x city x source serviceability.
--   dash.comp_brand_day    competitor brand x category x city x day.
--   dash.comp_sku_day      competitor SKU x city x day.
--   dash.fp_sales_daily    first-party sales: sales_date x sku_id x city,
--                          quantity + gmv (the source of GMV/ASP/units).
--   dash.fp_ad_page_perf   first-party ad page: impressions, clicks, orders,
--                          spend, revenue, roas.
--   dash.fp_fill_rate      weekly quantity/line fill rate.
--   dash.fp_po / fp_po_line / fp_grn_line / fp_invoice / fp_payment_advice /
--   fp_debit_credit_note / fp_ledger_entry   first-party supply-chain + finance.
--
-- Dimensions:
--   dash.dim_brand, dim_city (city_slug + city_name, pseudo-city 'ALL'),
--   dim_platform, dim_store, dim_sidnl (sidnl_id -> canonical product),
--   dim_product, dim_category, dim_date.
--
-- Prefer the pre-built views (they encode the roll-up rules):
--   dash.v_brand_scorecard / v_brand_scorecard_latest
--   dash.v_comp_price_gap, v_comp_sku_day, v_comp_cross_marketplace
--   dash.v_fp_sales_day / _sku / _city / _month / _health
--   dash.v_fp_ad_page, v_fp_ad_wallet_day, v_fp_sku_stock, v_fp_sku_cost
--   dash.v_fp_po_*, v_fp_invoice_recon, v_fp_finance_summary
--   dash.v_workspace_sov_keyword
--   dash.v_refresh_status, v_data_freshness, v_platform_freshness
--
-- Authoritative metric list (57 metrics with formula + status):
--   dash.metric_catalog
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Chatbot safety view: availability, city-level rows only.
-- Prevents the single most common Gold error: summing city totals together
-- with per-store rows and double-counting every observation.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW dash.v_chatbot_availability_city AS
SELECT
    obs_date, platform, city_slug, sidnl_id,
    ds_eligible_stores, ds_listed_stores, ds_listing_pct,
    osa_eligible_obs, osa_available_obs, osa_pct,
    osa_in_ls_eligible_obs, osa_in_ls_available_obs, osa_in_ls_pct,
    in_stock_stores, out_of_stock_stores, low_stock_stores,
    inventory_fe, inventory_fe_capped_stores, inventory_be, inventory_fe_be,
    drr, doi_fe, doi_be, doi_fe_be,
    is_critical, priority, potential_sales_loss,
    last_observed_at, refreshed_at, brand_id
FROM dash.availability
WHERE store_key IS NULL;

COMMENT ON VIEW dash.v_chatbot_availability_city IS
    'City-level availability only (store_key IS NULL). Safe to SUM: one row per '
    'SKU x city x day, no per-store rows to double-count.';

GRANT SELECT ON dash.v_chatbot_availability_city TO sidnl_chatbot_ro;
