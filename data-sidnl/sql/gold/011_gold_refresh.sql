-- =============================================================================
-- File:    gold/011_gold_refresh.sql
-- Purpose: Refresh all Gold materialized views in dependency order.
--          Run this after every Silver data load.
-- Run as:  postgres (Supabase SQL Editor)  OR  via cron / pg_cron
-- =============================================================================

-- ---------------------------------------------------------------------------
-- REFRESH ORDER (dependency-safe)
-- Base view (_base_silver) is a regular view — always live, no refresh needed.
-- Materialized views must be refreshed in this order:
-- 1. mv_osa_daily           (from _base_silver)
-- 2. mv_pricing_daily       (from _base_silver)
-- 3. mv_shelf_daily         (from _base_silver)
-- 4. mv_inventory_daily     (from _base_silver)
-- 5. mv_brand_daily         (from _base_silver)
-- 6. mv_sku_summary         (from _base_silver)
-- 7. mv_geography_daily     (from _base_silver)
-- 8. mv_category_daily      (from _base_silver)
-- 9. mv_platform_overview   (from _base_silver)
-- 10. mv_daily_trend        (from _base_silver)
-- 11. mv_price_parity       (from _base_silver)
-- 12. mv_competitor_comparison (from _base_silver)
-- 13. mv_rca_stockout       (from _base_silver — uses CURRENT_DATE)
-- Views derived from MVs (v_osa_d_minus, v_brand_shelf_share) are live.
-- ---------------------------------------------------------------------------

REFRESH MATERIALIZED VIEW gold.mv_osa_daily;
REFRESH MATERIALIZED VIEW gold.mv_pricing_daily;
REFRESH MATERIALIZED VIEW gold.mv_shelf_daily;
REFRESH MATERIALIZED VIEW gold.mv_inventory_daily;
REFRESH MATERIALIZED VIEW gold.mv_brand_daily;
REFRESH MATERIALIZED VIEW gold.mv_sku_summary;
REFRESH MATERIALIZED VIEW gold.mv_geography_daily;
REFRESH MATERIALIZED VIEW gold.mv_category_daily;
REFRESH MATERIALIZED VIEW gold.mv_platform_overview;
REFRESH MATERIALIZED VIEW gold.mv_daily_trend;
REFRESH MATERIALIZED VIEW gold.mv_price_parity;
REFRESH MATERIALIZED VIEW gold.mv_competitor_comparison;
REFRESH MATERIALIZED VIEW gold.mv_rca_stockout;

-- ---------------------------------------------------------------------------
-- OPTIONAL: pg_cron schedule (run as postgres in Supabase)
-- Uncomment and adjust if pg_cron extension is enabled.
-- ---------------------------------------------------------------------------
-- SELECT cron.schedule(
--     'gold-refresh',          -- job name
--     '0 * * * *',             -- every hour
--     $$
--         REFRESH MATERIALIZED VIEW gold.mv_osa_daily;
--         REFRESH MATERIALIZED VIEW gold.mv_pricing_daily;
--         REFRESH MATERIALIZED VIEW gold.mv_shelf_daily;
--         REFRESH MATERIALIZED VIEW gold.mv_inventory_daily;
--         REFRESH MATERIALIZED VIEW gold.mv_brand_daily;
--         REFRESH MATERIALIZED VIEW gold.mv_sku_summary;
--         REFRESH MATERIALIZED VIEW gold.mv_geography_daily;
--         REFRESH MATERIALIZED VIEW gold.mv_category_daily;
--         REFRESH MATERIALIZED VIEW gold.mv_platform_overview;
--         REFRESH MATERIALIZED VIEW gold.mv_daily_trend;
--         REFRESH MATERIALIZED VIEW gold.mv_price_parity;
--         REFRESH MATERIALIZED VIEW gold.mv_competitor_comparison;
--         REFRESH MATERIALIZED VIEW gold.mv_rca_stockout;
--     $$
-- );

-- ---------------------------------------------------------------------------
-- GRANT SELECT on all gold objects to ecomscraper_backend
-- (run once; default privileges handle future objects)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    obj record;
BEGIN
    FOR obj IN
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'gold'
    LOOP
        EXECUTE format('GRANT SELECT ON gold.%I TO ecomscraper_backend', obj.table_name);
    END LOOP;
END $$;
