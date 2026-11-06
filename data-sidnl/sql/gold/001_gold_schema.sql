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
