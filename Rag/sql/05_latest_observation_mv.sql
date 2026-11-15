-- =============================================================================
-- File:    05_latest_observation_mv.sql
-- Purpose: RUN THIS ONE as postgres / Supabase SQL editor. Makes
--          silver.v_latest_observation and silver.v_latest_shelf_position fast
--          (target: < 200 ms) by materialising the DISTINCT ON.
--
-- Why:     Both views are `DISTINCT ON (...) ... FROM silver.v_all_platforms`.
--          Postgres cannot push a brand / product / platform / store filter
--          through a DISTINCT ON, so a filtered query rebuilds and sorts every
--          row in silver.v_all_platforms. That relation is a 4-branch UNION ALL
--          over silver.blinkit / zepto / instamart / jiomart, which are
--          themselves views over silver.v_wide (a 6-way join whose physical
--          fact table is silver.fact_product_reading, 260k rows). Measured
--          8.9 s execution / 10.3 s wall for a simple brand+platform price
--          query, which trips the chatbot's 10 s statement_timeout.
--
-- Fix:     Materialise the latest row per (platform, listing, store) once,
--          index it, and point the two views at the materialised views. A
--          filtered lookup then becomes an index scan + small sort.
--
-- Notes:   * The chatbot role sidnl_chatbot_app is read-only and cannot create
--            objects; table/view owner is `postgres`. Run this as the owner.
--          * Safe to re-run: CREATE ... IF NOT EXISTS, CREATE OR REPLACE VIEW.
--          * Refreshing CONCURRENTLY requires the unique indexes created below.
--          * REFRESH MATERIALIZED VIEW CONCURRENTLY cannot run inside a
--            function, so the pg_cron jobs call it as a top-level statement.
--          * Refresh after each Silver load. Every 15 minutes is a safe
--            default; tighten it if the pipeline finishes more often.
-- =============================================================================

-- 1. Materialised views -------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS silver.mv_latest_observation AS
SELECT DISTINCT ON (platform, COALESCE(listing_id::text, platform_product_id), store_id)
       id, platform, source_type, source_record_id, listing_id, product_id,
       store_id, run_id, scrape_run_id,
       l1_id, l1_category, l2_id, l2_category, l3_id, l3_category,
       category_path, platform_product_id, sku_code, product_name, sku_name,
       brand, variant, product_description, product_url, image_url,
       pack_size, pack_unit, quantity, quantity_unit,
       mrp, sale_price, discount_amount, discount_percentage, price_per_unit,
       currency, inventory, inventory_capped, available_quantity,
       availability, stock_status, inventory_status, delivery_eta_minutes,
       "position", organic_position, is_ad, ad_type, product_type,
       store_external_id, store_name, city, city_slug, state, pincode,
       latitude, longitude, observed_at, scraped_at, transformed_at,
       source_url, scrape_status, scrape_backend, scrape_run_status,
       data_quality_status, validation_errors, raw_details, source_metadata,
       bronze_record_ids
FROM silver.v_all_platforms
WHERE source_type = 'observation'
ORDER BY platform, COALESCE(listing_id::text, platform_product_id), store_id,
         observed_at DESC
WITH NO DATA;

CREATE MATERIALIZED VIEW IF NOT EXISTS silver.mv_latest_shelf_position AS
SELECT DISTINCT ON (platform, COALESCE(listing_id::text, platform_product_id), store_id)
       id, platform, source_type, source_record_id, listing_id, product_id,
       store_id, run_id, scrape_run_id,
       l1_id, l1_category, l2_id, l2_category, l3_id, l3_category,
       category_path, platform_product_id, sku_code, product_name, sku_name,
       brand, variant, product_description, product_url, image_url,
       pack_size, pack_unit, quantity, quantity_unit,
       mrp, sale_price, discount_amount, discount_percentage, price_per_unit,
       currency, inventory, inventory_capped, available_quantity,
       availability, stock_status, inventory_status, delivery_eta_minutes,
       "position", organic_position, is_ad, ad_type, product_type,
       store_external_id, store_name, city, city_slug, state, pincode,
       latitude, longitude, observed_at, scraped_at, transformed_at,
       source_url, scrape_status, scrape_backend, scrape_run_status,
       data_quality_status, validation_errors, raw_details, source_metadata,
       bronze_record_ids
FROM silver.v_all_platforms
WHERE source_type = 'shelf_position'
ORDER BY platform, COALESCE(listing_id::text, platform_product_id), store_id,
         observed_at DESC
WITH NO DATA;

-- 2. Indexes ------------------------------------------------------------------
-- Unique index is mandatory for REFRESH ... CONCURRENTLY.
CREATE UNIQUE INDEX IF NOT EXISTS ux_mv_latest_obs_key
    ON silver.mv_latest_observation
       (platform, COALESCE(listing_id::text, platform_product_id), store_id);

CREATE UNIQUE INDEX IF NOT EXISTS ux_mv_latest_shelf_key
    ON silver.mv_latest_shelf_position
       (platform, COALESCE(listing_id::text, platform_product_id), store_id);

-- The chatbot's actual access pattern: filter by brand + platform (+ city).
CREATE INDEX IF NOT EXISTS ix_mv_latest_obs_brand_platform
    ON silver.mv_latest_observation (brand, platform);

CREATE INDEX IF NOT EXISTS ix_mv_latest_obs_brand_platform_city
    ON silver.mv_latest_observation (brand, platform, city);

CREATE INDEX IF NOT EXISTS ix_mv_latest_obs_platform_city
    ON silver.mv_latest_observation (platform, city);

CREATE INDEX IF NOT EXISTS ix_mv_latest_obs_brand_product
    ON silver.mv_latest_observation (brand, product_name);

CREATE INDEX IF NOT EXISTS ix_mv_latest_shelf_brand_platform
    ON silver.mv_latest_shelf_position (brand, platform);

CREATE INDEX IF NOT EXISTS ix_mv_latest_shelf_platform_city
    ON silver.mv_latest_shelf_position (platform, city);

-- 2b. Physical base-table index (the inline fast path) -----------------------
-- silver.blinkit / zepto / instamart / jiomart are VIEWS over silver.v_wide,
-- so they cannot be indexed. The physical table behind them is
-- silver.fact_product_reading (260k rows). It already has
-- ix_reading_prod_store_time (product_key, store_key, observed_at DESC), but
-- that index is not restricted to the rows the latest observation view reads,
-- so each product still fetches every reading (including the ~244k
-- brand_search / category_shelf rows) before filtering.
--
-- IMPORTANT: the views expose the *mapped* source type, i.e.
--   CASE source_type WHEN 'stock_check' THEN 'observation'
--                     ELSE 'shelf_position' END
-- Postgres does NOT simplify that back to `source_type = 'stock_check'`, so a
-- partial index written with the plain column predicate would never be chosen.
-- The predicate below uses the exact CASE expression the view inlines.
-- The observation slice is only 16,127 rows (~6%), so this index is selective;
-- the shelf slice is ~94% of the table, where the existing indexes/seq scan are
-- already appropriate, so no shelf partial index is added.
CREATE INDEX IF NOT EXISTS ix_reading_latest_observation
    ON silver.fact_product_reading (product_key, store_key, observed_at DESC)
    WHERE dq_status = 'valid'
      AND (CASE source_type
               WHEN 'stock_check' THEN 'observation'
               ELSE 'shelf_position'
           END) = 'observation';

-- 3. Populate ----------------------------------------------------------------
-- First population is non-concurrent (the MVs are empty, so CONCURRENTLY
-- would error with "materialized view has not been populated").
REFRESH MATERIALIZED VIEW silver.mv_latest_observation;
REFRESH MATERIALIZED VIEW silver.mv_latest_shelf_position;
ANALYZE silver.mv_latest_observation;
ANALYZE silver.mv_latest_shelf_position;

-- 4. Repoint the public views ------------------------------------------------
-- Column list and types are identical, so CREATE OR REPLACE keeps every
-- existing grant and dependent query working. (No dependent views exist today;
-- verified with pg_depend.)
CREATE OR REPLACE VIEW silver.v_latest_observation AS
SELECT * FROM silver.mv_latest_observation;

CREATE OR REPLACE VIEW silver.v_latest_shelf_position AS
SELECT * FROM silver.mv_latest_shelf_position;

-- 5. Grants ------------------------------------------------------------------
GRANT SELECT ON silver.mv_latest_observation TO sidnl_chatbot_app;
GRANT SELECT ON silver.mv_latest_shelf_position TO sidnl_chatbot_app;
GRANT SELECT ON silver.v_latest_observation TO sidnl_chatbot_app;
GRANT SELECT ON silver.v_latest_shelf_position TO sidnl_chatbot_app;

-- 6. Manual refresh helper ---------------------------------------------------
-- Plain REFRESH takes a brief exclusive lock. For zero-downtime refreshes run
-- the CONCURRENTLY statements in section 7 as a top-level statement instead
-- (Postgres forbids CONCURRENTLY inside a function).
CREATE OR REPLACE FUNCTION silver.refresh_latest_observation()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW silver.mv_latest_observation;
    REFRESH MATERIALIZED VIEW silver.mv_latest_shelf_position;
END;
$$;

GRANT EXECUTE ON FUNCTION silver.refresh_latest_observation() TO sidnl_chatbot_app;

-- 7. Schedule the refresh with pg_cron (already installed on this database) --
-- Two jobs because cron.schedule takes one statement per job; CONCURRENTLY
-- keeps readers unblocked while the ~7-17 s refresh runs.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'refresh-mv-latest-observation') THEN
            PERFORM cron.unschedule('refresh-mv-latest-observation');
        END IF;
        IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'refresh-mv-latest-shelf-position') THEN
            PERFORM cron.unschedule('refresh-mv-latest-shelf-position');
        END IF;

        PERFORM cron.schedule(
            'refresh-mv-latest-observation',
            '*/15 * * * *',
            'REFRESH MATERIALIZED VIEW CONCURRENTLY silver.mv_latest_observation'
        );
        PERFORM cron.schedule(
            'refresh-mv-latest-shelf-position',
            '*/15 * * * *',
            'REFRESH MATERIALIZED VIEW CONCURRENTLY silver.mv_latest_shelf_position'
        );
    ELSE
        RAISE NOTICE 'pg_cron not installed; schedule silver.refresh_latest_observation() from the pipeline instead.';
    END IF;
END;
$$;

-- 8. Verify ------------------------------------------------------------------
-- Expect two rows, both freshly populated, and index scans below 200 ms:
--
--   SELECT relname, relispopulated FROM pg_class
--    WHERE relname IN ('mv_latest_observation','mv_latest_shelf_position');
--
--   EXPLAIN (ANALYZE, BUFFERS)
--   SELECT platform, city, product_name, MIN(sale_price), MAX(sale_price)
--     FROM silver.v_latest_observation
--    WHERE brand = 'Mr. Munchies' AND platform = 'blinkit'
--    GROUP BY platform, city, product_name;
--
--   SELECT jobname, schedule, active FROM cron.job
--    WHERE jobname LIKE 'refresh-mv-latest-%';
--
--   -- Physical base-table partial index exists (expect 1):
--   SELECT indexname FROM pg_indexes
--    WHERE schemaname = 'silver'
--      AND tablename = 'fact_product_reading'
--      AND indexname LIKE 'ix_reading_latest_%'
--    ORDER BY indexname;

-- =============================================================================
-- ROLLBACK (only if you need to go back to the slow view definitions)
-- =============================================================================
-- CREATE OR REPLACE VIEW silver.v_latest_observation AS
-- SELECT DISTINCT ON (platform, COALESCE(listing_id::text, platform_product_id), store_id)
--        * FROM silver.v_all_platforms
--  WHERE source_type = 'observation'
--  ORDER BY platform, COALESCE(listing_id::text, platform_product_id), store_id,
--           observed_at DESC;
--
-- CREATE OR REPLACE VIEW silver.v_latest_shelf_position AS
-- SELECT DISTINCT ON (platform, COALESCE(listing_id::text, platform_product_id), store_id)
--        * FROM silver.v_all_platforms
--  WHERE source_type = 'shelf_position'
--  ORDER BY platform, COALESCE(listing_id::text, platform_product_id), store_id,
--           observed_at DESC;
--
-- SELECT cron.unschedule('refresh-mv-latest-observation');
-- SELECT cron.unschedule('refresh-mv-latest-shelf-position');
-- DROP INDEX IF EXISTS silver.ix_reading_latest_observation;
-- DROP MATERIALIZED VIEW IF EXISTS silver.mv_latest_observation;
-- DROP MATERIALIZED VIEW IF EXISTS silver.mv_latest_shelf_position;
-- DROP FUNCTION IF EXISTS silver.refresh_latest_observation();
