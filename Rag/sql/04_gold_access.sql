-- =============================================================================
-- File:    04_gold_access.sql
-- Purpose: RUN THIS ONE as postgres / Supabase SQL editor to let the chatbot
--          read the Gold (dash) layer. Safe to re-run; contains no DROP.
--
-- This is the runnable subset of 03_roles.sql (grants) + the Gold section of
-- 01_views.sql (safety view). Those files remain the source of truth.
--
-- After running this, the chatbot can answer Gold questions such as
-- "What was GMV last month?" or "What is Mr. Munchies' share of shelf on
-- Blinkit in Mumbai?" without returning UNSUPPORTED.
-- =============================================================================

-- 1. Schema access ------------------------------------------------------------
GRANT USAGE ON SCHEMA dash TO sidnl_chatbot_ro;

-- 2. Read the whole Gold layer ------------------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA dash TO sidnl_chatbot_ro;

-- 3. Keep working as new Gold tables/views appear -----------------------------
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA dash
    GRANT SELECT ON TABLES TO sidnl_chatbot_ro;

-- 4. Safety view: city-level availability only (store_key IS NULL) ------------
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

-- 5. Verify (run separately, as the chatbot role) ------------------------------
--   SELECT count(*) FROM dash.metric_catalog;                 -- expect 57
--   SELECT count(*) FROM dash.v_brand_scorecard_latest;       -- brand rows
--   SELECT count(*) FROM dash.v_fp_sales_day;                 -- sales days
--   SELECT count(*) FROM dash.v_chatbot_availability_city;    -- city rows
