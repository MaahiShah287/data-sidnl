-- =============================================================================
-- File:    05_latest_observation_mv.sql
-- Purpose: Makes silver.v_latest_observation and silver.v_latest_shelf_position
--          fast (target: < 200 ms) by materialising the DISTINCT ON.
--
-- HOW TO RUN IN THE SUPABASE SQL EDITOR
-- -------------------------------------
-- The dashboard has an upstream/gateway timeout, so DO NOT paste this whole
-- file at once. Run the phases below ONE AT A TIME: select a phase, click Run,
-- wait for "Success", then run the next phase.
--
--   Phase 1  create the two materialised views + their indexes   (instant)
--   Phase 2  OPTIONAL base-table index (one statement, see below)
--   Phase 3  populate mv_latest_observation                      (~1-20 s)
--   Phase 4  populate mv_latest_shelf_position                   (~8-30 s)
--   Phase 5  analyze, repoint the public views, grant SELECT     (instant)
--   Phase 6  schedule the 15-minute pg_cron refresh              (instant)
--
-- If Phase 3 or Phase 4 still times out in the dashboard, use the pg_cron
-- fallback at the end: it runs the refresh server-side, so the editor returns
-- immediately. Alternatively run the whole file with psql / the Supabase CLI,
-- which has no dashboard gateway timeout.
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
-- Notes:   * Run as the owner (postgres). sidnl_chatbot_app is read-only.
--          * Safe to re-run: CREATE ... IF NOT EXISTS, CREATE OR REPLACE VIEW.
--          * Phase 2 uses CREATE INDEX CONCURRENTLY, so it never blocks the
--            Silver loader's inserts. It must be submitted as a SINGLE
--            statement (no SET, nothing else) because Postgres forbids
--            CONCURRENTLY inside a transaction block.
--          * Refreshing CONCURRENTLY requires the unique indexes created below.
--          * REFRESH MATERIALIZED VIEW CONCURRENTLY cannot run inside a
--            function, so the pg_cron jobs call it as a top-level statement.
--          * Refresh after each Silver load. Every 15 minutes is a safe
--            default; tighten it if the pipeline finishes more often.
-- =============================================================================


-- ############################################################################
-- PHASE 1 — create the materialised views and their indexes
-- ############################################################################
SET statement_timeout = 0;

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


-- ############################################################################
-- PHASE 2 (OPTIONAL) — physical base-table partial index (the inline fast path)
-- ############################################################################
-- SKIP THIS PHASE IF YOU ARE BLOCKED: the materialised views (Phases 3-6) are
-- the fix for the public views. This index only shaves the app-side inline
-- rewrite, which is already ~80-220 ms without it.
--
-- Why this phase is ONE statement, with no SET and no other SQL:
--   * silver.blinkit / zepto / instamart / jiomart are VIEWS over silver.v_wide
--     and cannot be indexed. The physical table is silver.fact_product_reading
--     (260k rows, 154 MB). Its existing ix_reading_prod_store_time is not
--     restricted to the rows the latest views read, so each product still
--     fetches the ~244k brand_search / category_shelf rows before filtering.
--   * A plain CREATE INDEX takes a SHARE lock, which conflicts with the
--     RowExclusiveLock the Silver loader holds while inserting. The build is
--     only ~1 s, but it waits in the lock queue until the loader's transaction
--     ends, so the dashboard's upstream timeout fires first.
--   * CREATE INDEX CONCURRENTLY only needs ShareUpdateExclusiveLock, which is
--     compatible with inserts, so it does not block (or queue behind) the
--     loader. Postgres refuses to run it inside a transaction block, so it
--     must be submitted ALONE: no SET statement_timeout, no other statement.
--
-- IMPORTANT: the views expose the *mapped* source type, i.e.
--   CASE source_type WHEN 'stock_check' THEN 'observation'
--                     ELSE 'shelf_position' END
-- Postgres does NOT simplify that back to `source_type = 'stock_check'`, so a
-- partial index written with the plain column predicate would never be chosen.
-- The predicate below uses the exact CASE expression the view inlines.
-- The observation slice is 16,127 rows (~6%), so this index is selective; the
-- shelf slice is ~94% of the table, where the existing indexes are already
-- appropriate, so no shelf partial index is added.

-- >>> SELECT ONLY THE NEXT STATEMENT, THEN RUN. Nothing else in the tab. <<<
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_reading_latest_observation
    ON silver.fact_product_reading (product_key, store_key, observed_at DESC)
    WHERE dq_status = 'valid'
      AND (CASE source_type
               WHEN 'stock_check' THEN 'observation'
               ELSE 'shelf_position'
           END) = 'observation';

-- Verify (run separately). indisvalid must be true:
--   SELECT c.relname AS index_name, i.indisvalid
--     FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
--    WHERE c.relname = 'ix_reading_latest_observation';
--
-- If an earlier attempt left an INVALID index, drop it BY ITSELF, then re-run
-- the CREATE INDEX CONCURRENTLY statement above:
--   DROP INDEX CONCURRENTLY IF EXISTS silver.ix_reading_latest_observation;
--
-- A concurrent build still waits for transactions that already modified the
-- table. If it hangs, look for a leaked idle-in-transaction session (as
-- postgres) and terminate it only if it is stale:
--   SELECT pid, state, now() - xact_start AS xact_age, left(query, 80)
--     FROM pg_stat_activity
--    WHERE datname = current_database() AND xact_start IS NOT NULL
--    ORDER BY xact_start;
--
-- If the editor rejects CONCURRENTLY with
--   "CREATE INDEX CONCURRENTLY cannot run inside a transaction block"
-- (older dashboards wrap every submission in a transaction), or the request
-- times out again, schedule the build with pg_cron instead. The job body must
-- be ONE statement; the editor returns immediately and pg_cron builds the index
-- server-side, so there is no dashboard timeout:
--
--   SELECT cron.schedule(
--       'build-ix-reading-latest-observation',
--       '* * * * *',
--       $job$CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_reading_latest_observation
--                ON silver.fact_product_reading (product_key, store_key, observed_at DESC)
--               WHERE dq_status = 'valid'
--                 AND (CASE source_type WHEN 'stock_check' THEN 'observation'
--                                       ELSE 'shelf_position' END) = 'observation'$job$
--   );
--
--   -- after ~1 minute:
--   SELECT jobname, status, return_message, start_time
--     FROM cron.job_run_details
--    WHERE jobname = 'build-ix-reading-latest-observation'
--    ORDER BY start_time DESC LIMIT 5;
--
--   -- once status = 'succeeded' and indisvalid = true, stop the every-minute job:
--   SELECT cron.unschedule('build-ix-reading-latest-observation');
--
-- Or run the CREATE INDEX CONCURRENTLY statement with psql / the Supabase CLI,
-- which have no dashboard gateway timeout.


-- ############################################################################
-- PHASE 3 — populate mv_latest_observation (run alone)
-- ############################################################################
SET statement_timeout = 0;

-- First population is non-concurrent (an unpopulated MV cannot be refreshed
-- CONCURRENTLY). This is the heavy step; keep it in its own request.
REFRESH MATERIALIZED VIEW silver.mv_latest_observation;


-- ############################################################################
-- PHASE 4 — populate mv_latest_shelf_position (run alone)
-- ############################################################################
SET statement_timeout = 0;

REFRESH MATERIALIZED VIEW silver.mv_latest_shelf_position;


-- ############################################################################
-- PHASE 5 — analyze, repoint the public views, grant SELECT
-- ############################################################################
SET statement_timeout = 0;

ANALYZE silver.mv_latest_observation;
ANALYZE silver.mv_latest_shelf_position;

-- Column list and types are identical, so CREATE OR REPLACE keeps every
-- existing grant and dependent query working. (No dependent views exist today;
-- verified with pg_depend.)
CREATE OR REPLACE VIEW silver.v_latest_observation AS
SELECT * FROM silver.mv_latest_observation;

CREATE OR REPLACE VIEW silver.v_latest_shelf_position AS
SELECT * FROM silver.mv_latest_shelf_position;

GRANT SELECT ON silver.mv_latest_observation TO sidnl_chatbot_app;
GRANT SELECT ON silver.mv_latest_shelf_position TO sidnl_chatbot_app;
GRANT SELECT ON silver.v_latest_observation TO sidnl_chatbot_app;
GRANT SELECT ON silver.v_latest_shelf_position TO sidnl_chatbot_app;

-- Manual refresh helper (owner-only: REFRESH needs table ownership, so the
-- read-only app role cannot call it and no EXECUTE grant is given). Plain
-- REFRESH takes a brief exclusive lock; the pg_cron jobs below use CONCURRENTLY
-- instead (Postgres forbids CONCURRENTLY inside a function).
CREATE OR REPLACE FUNCTION silver.refresh_latest_observation()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW silver.mv_latest_observation;
    REFRESH MATERIALIZED VIEW silver.mv_latest_shelf_position;
END;
$$;


-- ############################################################################
-- PHASE 6 — schedule the 15-minute pg_cron refresh
-- ############################################################################
SET statement_timeout = 0;

-- Two jobs because cron.schedule takes one statement per job; CONCURRENTLY
-- keeps readers unblocked while the ~1-8 s warm refresh runs.
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


-- =============================================================================
-- VERIFY (run after all phases)
-- =============================================================================
-- Expect two rows, both populated, and index scans below 200 ms:
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
-- FALLBACK — populate via pg_cron if Phase 3/4 still times out
-- =============================================================================
-- The editor returns immediately after scheduling; pg_cron runs the refresh
-- server-side. Uncomment and run this block only if a REFRESH timed out.
-- WARNING: '* * * * *' runs every minute until you unschedule it, so unschedule
-- the temporary jobs as soon as both MVs are populated.
--
-- SELECT cron.schedule(
--     'populate-mv-observation-once', '* * * * *',
--     'REFRESH MATERIALIZED VIEW silver.mv_latest_observation');
-- SELECT cron.schedule(
--     'populate-mv-shelf-once', '* * * * *',
--     'REFRESH MATERIALIZED VIEW silver.mv_latest_shelf_position');
--
-- Wait ~1 minute, then check:
-- SELECT relname, relispopulated FROM pg_class
--  WHERE relname IN ('mv_latest_observation','mv_latest_shelf_position');
-- SELECT jobname, status, return_message, start_time
--   FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;
--
-- Once both are populated, unschedule the temporary jobs:
-- SELECT cron.unschedule('populate-mv-observation-once');
-- SELECT cron.unschedule('populate-mv-shelf-once');


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
