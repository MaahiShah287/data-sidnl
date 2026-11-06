-- =============================================================================
-- File:    02_diagnostics.sql
-- Purpose: Data profiling queries — run against Supabase before finalising views.
-- =============================================================================

-- BLOCK 1a: scrape_status distribution per platform
SELECT platform, scrape_status, COUNT(*) AS row_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY platform), 2) AS pct
FROM (
    SELECT platform, scrape_status FROM silver.blinkit   UNION ALL
    SELECT platform, scrape_status FROM silver.zepto     UNION ALL
    SELECT platform, scrape_status FROM silver.instamart UNION ALL
    SELECT platform, scrape_status FROM silver.jiomart
) t
GROUP BY platform, scrape_status ORDER BY platform, row_count DESC;

-- BLOCK 1b: scrape_run_status distribution per platform
SELECT platform, scrape_run_status, COUNT(*) AS row_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY platform), 2) AS pct
FROM (
    SELECT platform, scrape_run_status FROM silver.blinkit   UNION ALL
    SELECT platform, scrape_run_status FROM silver.zepto     UNION ALL
    SELECT platform, scrape_run_status FROM silver.instamart UNION ALL
    SELECT platform, scrape_run_status FROM silver.jiomart
) t
GROUP BY platform, scrape_run_status ORDER BY platform, row_count DESC;

-- BLOCK 1c: data_quality_status
SELECT platform, data_quality_status, COUNT(*) AS row_count
FROM (
    SELECT platform, data_quality_status FROM silver.blinkit   UNION ALL
    SELECT platform, data_quality_status FROM silver.zepto     UNION ALL
    SELECT platform, data_quality_status FROM silver.instamart UNION ALL
    SELECT platform, data_quality_status FROM silver.jiomart
) t GROUP BY platform, data_quality_status ORDER BY platform, row_count DESC;

-- BLOCK 2: NULL rate per key column per platform+source_type
SELECT platform, source_type, COUNT(*) AS total_rows,
    SUM(CASE WHEN listing_id IS NULL THEN 1 ELSE 0 END) AS null_listing_id,
    SUM(CASE WHEN store_id IS NULL THEN 1 ELSE 0 END) AS null_store_id,
    SUM(CASE WHEN availability IS NULL THEN 1 ELSE 0 END) AS null_availability,
    SUM(CASE WHEN sale_price IS NULL THEN 1 ELSE 0 END) AS null_sale_price,
    SUM(CASE WHEN mrp IS NULL THEN 1 ELSE 0 END) AS null_mrp,
    SUM(CASE WHEN discount_percentage IS NULL THEN 1 ELSE 0 END) AS null_discount_pct,
    SUM(CASE WHEN position IS NULL THEN 1 ELSE 0 END) AS null_position,
    SUM(CASE WHEN organic_position IS NULL THEN 1 ELSE 0 END) AS null_organic_position
FROM (
    SELECT platform, source_type, listing_id, store_id, availability, sale_price,
           mrp, discount_percentage, position, organic_position FROM silver.blinkit UNION ALL
    SELECT platform, source_type, listing_id, store_id, availability, sale_price,
           mrp, discount_percentage, position, organic_position FROM silver.zepto UNION ALL
    SELECT platform, source_type, listing_id, store_id, availability, sale_price,
           mrp, discount_percentage, position, organic_position FROM silver.instamart UNION ALL
    SELECT platform, source_type, listing_id, store_id, availability, sale_price,
           mrp, discount_percentage, position, organic_position FROM silver.jiomart
) t GROUP BY platform, source_type ORDER BY platform, source_type;

-- BLOCK 3: Cross source-type overlap
WITH base AS (
    SELECT platform, COALESCE(listing_id, platform_product_id) AS eid, store_id, source_type
    FROM (
        SELECT platform, listing_id, platform_product_id, store_id, source_type FROM silver.blinkit   UNION ALL
        SELECT platform, listing_id, platform_product_id, store_id, source_type FROM silver.zepto     UNION ALL
        SELECT platform, listing_id, platform_product_id, store_id, source_type FROM silver.instamart UNION ALL
        SELECT platform, listing_id, platform_product_id, store_id, source_type FROM silver.jiomart
    ) r
),
pivoted AS (
    SELECT platform, eid, store_id,
        BOOL_OR(source_type = 'observation') AS has_obs,
        BOOL_OR(source_type = 'shelf_position') AS has_shelf
    FROM base GROUP BY platform, eid, store_id
)
SELECT platform,
    COUNT(*) FILTER (WHERE has_obs AND has_shelf) AS overlap_count,
    COUNT(*) FILTER (WHERE has_obs AND NOT has_shelf) AS obs_only,
    COUNT(*) FILTER (WHERE NOT has_obs AND has_shelf) AS shelf_only
FROM pivoted GROUP BY platform ORDER BY platform;

-- BLOCK 4: Duplicate source_record_id
SELECT platform, source_type, source_record_id, COUNT(*) AS dup_count
FROM (
    SELECT platform, source_type, source_record_id FROM silver.blinkit   UNION ALL
    SELECT platform, source_type, source_record_id FROM silver.zepto     UNION ALL
    SELECT platform, source_type, source_record_id FROM silver.instamart UNION ALL
    SELECT platform, source_type, source_record_id FROM silver.jiomart
) t
WHERE source_record_id IS NOT NULL
GROUP BY platform, source_type, source_record_id HAVING COUNT(*) > 1
ORDER BY dup_count DESC LIMIT 100;

-- BLOCK 5: Temporal coverage and city row counts
SELECT platform, source_type, COUNT(*) AS total_rows,
    MIN(observed_at) AS earliest, MAX(observed_at) AS latest
FROM (
    SELECT platform, source_type, observed_at FROM silver.blinkit   UNION ALL
    SELECT platform, source_type, observed_at FROM silver.zepto     UNION ALL
    SELECT platform, source_type, observed_at FROM silver.instamart UNION ALL
    SELECT platform, source_type, observed_at FROM silver.jiomart
) t GROUP BY platform, source_type ORDER BY platform, source_type;
