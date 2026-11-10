# Silver + dash: correctness and efficiency pass (2026-11-10)

Each change was applied as a Supabase migration after a dry run in a transaction that was rolled back, and checked
live afterwards. Exact applied SQL is in `sql/*/live/`; rollbacks are next to it (`sql/silver/NNN_rollback.sql`,
`sql/dash/NNN_rollback.sql`). No bronze table (any schema except `silver`/`dash`) was written.

## What changed

| Migration (version) | Problem found (real data) | Fix | Live proof |
|---|---|---|---|
| `dash_006_gold_failure_retry` (20261110094854) | A failed `dash.refresh` was marked gold "success" and never retried; a timeout looped every minute | Gold failure → `failed` + Silver backoff; timeout caught; `dash.v_refresh_status` | First real refresh filled all 10 table rows |
| `silver_056_parse_pack_counts` (20261110101147) | 2,106 products had wrong size/pack (`10 tabs` → 1 pc; `10 pcs` → total 100; `100 g X 2` → 100 g; `7 pcs + 102 g` → 714 g) | Parser fixed + bronze strings added to its self-test; rows re-derived from their own `pack_raw` | Forced run 782 success; 0 products / 0 canonicals / 0 dash dims out of sync |
| `dash_007_visibility_full_rebuild` (20261110102500) | `dash.visibility` older than 3 days kept SI ids from before renumbering: **10,427 rows (~560k impressions) credited to the wrong products**; 11-06 missing | Gold rebuilds every visibility date (config `gold_visibility_days`, NULL = all); +9 s per refresh | Every date: 0 stale rows, 0 impression differences |
| `silver_057_seen_dates_and_stale_review` (20261110103405) | 63 `first_seen_at` later than the product's first fact; 1 stale review | Set from own facts (old values in `ops.backup_silver_057`); review closed | 0 late dates |
| `silver_058_auto_exact_match` (20261110103437) | No SI id spanned two platforms; certain matches waited for a human | Cron `sidnl-auto-match` (10 min) approves only exact twins: same brand, same normalized name, same parsed size/unit/pack, other platform. Fuzzy matches never auto-approved | 4 Amul SKUs now one SI id across Blinkit + Zepto; SI ids resequenced 1..7,137, 0 out of order |
| `silver_059_maintenance_automation` (20261110103810) | 27 tables had no planner statistics (planner thought `fact_product_reading` was empty); `cron.job_run_details` never purged | ANALYZE; cron `sidnl-maintenance` (daily 19:05 UTC) purges cron history > 14 days and analyzes tables without statistics | Planner now sees 56,249 / 4,777 rows |
| `dash_008_brand_scorecard` (20261110104140) + `dash_009_brand_scorecard_fast` (20261110104441) | No single place for a brand to read its own market position | `dash.v_brand_scorecard` and `dash.v_brand_scorecard_latest` (below) | Brand impressions sum exactly to market on every day/city; `ALL` = sum of cities; OSA equals direct calc; 7.5 s → 89 ms |

## Brand scorecard (`dash.v_brand_scorecard`, `dash.v_brand_scorecard_latest`)
One row per obs_date × platform × city (`ALL` = all cities) × brand, computed only from `dash.visibility`,
`dash.availability` and `dash.pricing`:
- **Shelf:** `share_of_shelf_pct` = brand impressions ÷ all impressions on the tracked category shelves (with
  `shelf_impressions` / `market_shelf_impressions`), `top_of_shelf_share_pct`, `shelf_rank_among_brands`,
  `brands_on_shelf`, `categories_present` / `categories_tracked`, `best_shelf_rank`.
- **Availability:** `osa_pct` (`osa_available_obs` / `osa_eligible_obs`), `listing_pct` (`listed_stores` /
  `eligible_stores`), `skus_with_stockouts`, `potential_sales_loss`.
- **Pricing:** `avg_discount_pct` (`sum_mrp`, `sum_selling_price`), `parity_breaks` / `parity_checked`.
- **NULL means not measured.** Today category shelves exist for Blinkit only; availability/pricing exist for client
  brands only; OSA (stock checks) exists for Mr Munchies only. Roll up with SUM(num)/SUM(den), never by averaging %.

Latest values for client brands (`city_slug = 'ALL'`):

| Brand | Platform | Date | Share of shelf | Rank (of brands on shelf) | OSA % | Listing % | Avg discount % |
|---|---|---|---|---|---|---|---|
| Amul | Blinkit | 11-09 | 2.685 | 6 of 537 | — | — | 5.33 |
| Amul | Zepto | 11-08 | — | — | — | 94.51 | 2.95 |
| Mother Dairy | Blinkit | 11-06 | — | — | — | 100 | 6.67 |
| Mr. Munchies | Blinkit | 11-08 | 1.584 | 16 of 132 | 1.59 | 25 | 6.97 |

## Automations now running (pg_cron)
`sidnl-pipeline` (every minute), `sidnl-gold` (every minute), `sidnl-pipeline-daily` (18:35 UTC),
`sidnl-auto-match` (every 10 min), `sidnl-maintenance` (19:05 UTC daily).

## Not done, and why
- **Storing the SI id in every silver table: deliberately not done.** SI ids are renumbered A–Z in 36 of the last 54
  runs (up to 7,108 ids per run). Facts keep the stable `product_key`; `product_xref` holds the one SI id per product.
  Copying the SI id into the 1.83M-row fact table would rewrite most of it on every renumbering.
- **Unused-looking indexes kept:** they back foreign keys (`store_key`, `etl_run_id`, `product_key`) or `sidnl_find` search.
- **Scale:** gold rebuilds dash in full (~38 s today). At much larger volumes this needs an incremental refresh keyed by a
  stable id, which means changing dash table keys and needs its own design.
- **40 fuzzy match reviews** remain in `silver.match_review_queue`. Several high-score suggestions are wrong, so they need a human.
- **Coverage gaps (data, not code):** 10,787 bronze stock checks for non-client brands are outside `silver.brand_scope`;
  Instamart/JioMart have no rows; Zepto observations stopped on 10-30.
- Fallback Gaps 2–5 (freshness, dead-letter, alert delivery, heartbeat) from `docs/fallbacks-design.md` are still to do.
