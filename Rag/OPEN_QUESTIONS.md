# OPEN_QUESTIONS.md

Items requiring confirmation before code or metric definitions can be finalised.
Add results from diagnostics here.

## SQL Views (sql/01_views.sql)

- [OPEN] Valid values for `scrape_status` and `scrape_run_status` → needed to fill TODO(diagnostics) stubs in 01_views.sql. Run sql/02_diagnostics.sql Block 1 against Supabase.
- [OPEN] Is `listing_id` guaranteed non-null for all four platforms? The views fall back to `platform_product_id`. Owner: scraping team.
- [OPEN] Is `scrape_run_id` monotonically increasing globally (not just per scraper)? If per-scraper only, partition v_latest_shelf_position ORDER BY by scrape_backend too. Owner: data-engineering lead.

## Metrics

- [OPEN] `observed_in_stock_rate`: Should NULL `availability` rows be excluded from denominator (current draft) or treated as a separate "unknown" bucket? Owner: analytics mentor.
- [OPEN] `avg_discount_pct`: Simple average vs weighted (by listing count or inventory)? Owner: analytics mentor.
- [OPEN] `ad_placement_rate`: Are observation rows with `is_ad` populated valid ad signals, or should ad metrics use shelf_position rows exclusively? Owner: data-engineering lead + analytics mentor.

## Data Quality (pending Stage A profiler run)

- [OPEN] Are there rows where both source_type=observation AND source_type=shelf_position exist for the same (platform, listing_id, store_id)? Run Block 3 of sql/02_diagnostics.sql.
- [OPEN] What is the NULL rate on `availability` per platform? If > 20%, flag as a data-quality issue.

## Metric Definitions Pending

- [OPEN] SOV (Share of Voice): company definition not yet agreed. Status: unsupported.
- [OPEN] SOH (Share of Shelf): company definition not yet agreed. Status: unsupported.

## Stage A (profile_data.py)

- [OPEN] DATABASE_URL not configured — profiler script has not been run. 
  To run: (1) copy .env.example to .env, (2) fill in DATABASE_URL with sidnl_chatbot_ro credentials, (3) run: python scripts/profile_data.py
  Results must be pasted here before the view TODOs can be filled.
