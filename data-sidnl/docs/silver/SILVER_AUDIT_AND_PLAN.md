# Silver audit, findings and implementation plan

Date: 2026-11-08 (IST). Scope: Silver only. Gold is not touched in phases 1-3.
Method: read-only queries against the live Supabase project `SIDNL`, plus the repo. No row was changed during the audit.
No demo or sample data was used or added.

## 1. Baseline: reported values vs the live database

| Component | Reported | Live now | Note |
|---|---:|---:|---|
| Shelf records | 508,760 | 570,136 | +61,376 from four categories the scheduler loaded on its own (Chips & Crisps, Noodles, Indian Sweets, Chocolates). Soft Drinks (507,770) + Frozen Veg (990) = 508,760, so the reported figure matches. |
| In stock / out of stock | 427,757 / 81,003 | 481,310 / 88,826 | same reason |
| Products in dim_product | 721 | 2,021 | same reason |
| SI ids | SI001-SI721 | SI001-SI2020, 2,016 active, 4 retired | the 4 retired are exact duplicates merged on 2026-11-07 (migration 032); one more was merged automatically afterwards, so 5 SI ids now hold 2 Blinkit ids |
| Missing SI ids | 0 | 0 | |
| Brands in dim_brand | 134 competitors | 371 | grows as categories load; only 2 are tracked |
| Unlinked shelf rows | 42 | 42 | all in Frozen Veg Snacks (see F1) |
| Loaded platforms | Blinkit | Blinkit | cross-platform matching still unexercised on real data |
| `pipeline_min_interval_seconds` | "10 minutes" | 120 seconds | the doc says 600; the live value is 120. Effective gap between runs is about 3 minutes (cron tick + 120 s debounce) |
| Database size | 673 MB | 688 MB | |

Enabled brands: `mr munchies`, `mother dairy` (confirmed). 371 rows in `brand_scope`, 2 tracked in `dim_brand`.

## 2. Inventory

36 tables, 21 views, 46 functions, 0 triggers in schema `silver`. Largest: `fact_shelf_position` 355 MB total (266 MB table + 88 MB indexes), then `fact_product_reading` 5 MB, `dim_product` 3.7 MB. Everything else is under 2 MB.

Automation objects: `silver.run_pipeline(force, trigger)`, `refresh_brand`, `refresh_category_market`, `refresh_category_products`, `map_new_products`, `sync_canonical_attrs`, `quality_checks`, `register_category_scopes`, `onboard_brands`, `register_platforms`; tables `pipeline_source` (watermarks), `pipeline_run`, `etl_run`, `sidnl_config`; view `v_pipeline_status`.

pg_cron: `sidnl-pipeline` every minute and `sidnl-pipeline-daily` at 18:35 UTC (00:05 IST). Both use `set statement_timeout='600s'`.

## 3. Column profile (columns with NULL, empty or placeholder values)

Every other column in the profiled tables is 100% populated. Profiled: all dimensions, `canonical_product`, `product_xref`, `fact_shelf_position` (570,136 rows), `fact_product_reading` (6,054), `fact_store_scan` (2,382), `brand_scope`, `category_scope`.

Classes: 1 = wrong value, deterministically correctable; 2 = optional, keep NULL; 3 = never supplied by the source; 4 = not applicable; 5 = required, needs investigation.

| Table.column | Rows | NULL | % | Class | Treatment |
|---|---:|---:|---:|---|---|
| fact_shelf_position.ad_type | 570,136 | 553,600 | 97.1 | 4 | NULL for non-ads (16,536 ads). Keep. |
| fact_shelf_position.organic_position | 570,136 | 16,536 | 2.9 | 4 | NULL exactly for ads. Keep. |
| fact_shelf_position.city_slug | 570,136 | 47,211 | 8.3 | 3 | Store has no coordinates (F3). Keep NULL, flag. |
| fact_shelf_position.shelf_total_items | 570,136 | 50 | 0.01 | 3 | 3 snapshots (691, 938, 999) never reported a total (F5). Keep NULL. |
| fact_shelf_position.product_key | 570,136 | 42 | 0.01 | 1 | 11 products missing from `dim_product` (F1). Correct. |
| fact_product_reading.selling_price / mrp / discount_* | 6,054 | 377 | 6.2 | 4 | All 377 are out_of_stock readings. Keep. |
| fact_product_reading.search_position, organic_position, is_ad, snapshot_id, scrape_id, planned_store_key | 6,054 | 2,791 | 46.1 | 4 | Stock-check readings have no search context. Keep. |
| fact_product_reading.run_id, listing_id | 6,054 | 3,263 | 53.9 | 4 | Search readings have no stock-check run. Keep. |
| fact_product_reading.ad_type | 6,054 | 6,054 | 100 | 4 | Never captured. Keep. |
| fact_product_reading.city_slug | 6,054 | 17 | 0.3 | 3 | Same store gap as F3. |
| fact_store_scan.store_key | 2,382 | 102 | 4.3 | 4 | Scans that failed to resolve a store; already excluded from the listing-% base by `is_valid_denominator`. Keep. |
| fact_store_scan.scan_status = 'empty' | 2,382 | - | - | valid | A real status (ok 2,280 / failed 100 / empty 2). Not a placeholder. |
| dim_store.store_name | 1,085 | 1,085 | 100 | 3 | Blinkit stores have no name in `public.stores` (0 of Blinkit; Zepto 282, demo 83). Keep NULL. |
| dim_store.latitude / longitude / city_slug | 1,085 | 182 | 16.8 | 3 | No coverage or sample-point rows exist for these stores, so the city cannot be derived (F3). Keep NULL. |
| dim_store.store_weight | 1,085 | 1,085 | 100 | 3 | Placeholder column for client store sales. Empty until supplied. |
| dim_product.catalog_product_id, listing_id, product_url | 2,021 | 2,020 | 100 | 4 | Client catalog links; only the one tracked listing has them. Keep. |
| dim_product.category_key | 2,021 | 14 | 0.7 | 3 | Client products seen only in brand search; no category scraped (F4). Keep NULL. |
| dim_product.variant | 2,021 | 149 | 7.4 | 2 | No variant in the name. Keep. Plus 4 rows with variant `-` (F8). |
| canonical_product.category_l1 / l2 | 2,020 | 14 | 0.7 | 3 | Same 14 products. |
| canonical_product.category_l3 | 2,020 | 2,012 | 99.6 | 3 | L3 exists only where a product page was scraped (8 rows). Not on shelf reads. |
| canonical_product.merged_into | 2,020 | 2,016 | 99.8 | 4 | Set only for the 4 retired ids. |
| canonical_product.name_clean = '' | 2,020 | 0 | - | 1/5 | 34 rows are empty strings (F9). |
| canonical_product.variant_key = '' | 2,020 | 0 | - | 1 | 181 empty strings; 149 with no variant, 32 whose variant is only noise words. Should be NULL (F8). |
| dim_brand.company_name, brand_scope.company_name | 371 | 369 | 99.5 | 3 | Only 2 companies exist in `public.companies`. Keep. |
| product_xref.reviewed_by / reviewed_at | 2,021 | 2,017 | 99.8 | 4 | Set only for the 4 merged. |

No other placeholder strings (EMPTY, NULL, N/A, NA, UNKNOWN) exist in any profiled column.

## 4. Findings

Classification: **S** safe deterministic correction, **B** business decision required, **D** potentially destructive, **L** source-data limitation.

### Data quality

| # | Finding | Class |
|---|---|---|
| F1 | 42 shelf rows (11 distinct products, 7 brands: Aashirvaad, Amul, Blue Tribe Foods, Handi, Hungritos, ITC Master Chef, McCain) in Frozen Veg Snacks 15/1413 have no `dim_product` row. All 42 exist in `public.platform_products`, so the product loader can create the rows. Cause: that category was loaded before the product loader existed and the incremental loader never revisits it. | S |
| F2 | 2 shelf rows carry `brand_key = 'blue tribe foods'`, which is not in `dim_brand`. Fact tables have no FK on `brand_key`, so nothing prevents this. | S |
| F3 | 182 stores (16.8%) have no coordinates or city; 180 are used by facts (47,211 shelf rows, 8.3%). None appears in `public.coverage`, so the city cannot be derived without guessing. | L |
| F4 | 14 client products have no category (seen only through brand search). | L |
| F5 | 3 shelf snapshots have no `total_items`, so shelf coverage cannot be computed for 50 rows. | L |
| F6 | **Pack parser ignores bonus quantities.** 88 products have packs like `225 ml + 225 ml` or `5 x 500 g + 5 x 500 g`; they parse as 225 ml x1 and 500 g x5, so `total_content` is understated by half. Four pairs of different SKUs therefore share identical size and pack count (Dobra Pop Goli Banta, Jimmy's Jamun Mint, Jimmy's Orange, Pepsi 2 x 750). | S (parser fix; SI ids unchanged) |
| F7 | 75 product names contain leading, trailing or repeated spaces. | S (add a standardised column; keep the raw name) |
| F8 | 4 variants are the literal `-` (for example "Fanta - Orange Soft Drink"); 181 `variant_key` values are empty strings where NULL is meant. | S |
| F9 | 34 canonical products have an empty `name_clean` (for example "Coca-Cola Soft Drink"), so name similarity cannot separate them. This matters for cross-platform matching later. | B |
| F10 | `variant_key` / `name_clean` collapse genuinely different flavours: Lemon vs Lime (Maison Perrier), Lemon-Lime vs Lemon (Sprite) get identical keys. These pairs must never auto-merge. Cherry vs Cherry Flavoured (Coca-Cola, SI121 / SI449) is probably the same product. | B |
| F11 | Prices are clean: 0 negative, 0 zero, 0 price > MRP, 0 null on in-stock rows across 570,136 shelf rows and 6,054 readings. `dq_status` is `valid` on every row and `dq_flags` is empty. | - |
| F12 | No duplicate facts (`source_record_id` unique, no repeated snapshot + product + position). No dangling product, category, platform or store keys. | - |
| F13 | Canonical integrity is intact: every product has an SI id, no xref points to a retired id, no orphan xref, no missing anchor, 0 exact duplicates. | - |

### Automation

| # | Finding |
|---|---|
| A1 | The scheduler works: 559 successful ticks in 24 h, mostly 2 s idle checks; real runs average 23 s. Run 44 loaded four new categories with no manual step. |
| A2 | `run_pipeline` calls `gold.refresh_all()`. That conflicts with "stop the pipeline at validated Silver". Mr Munchies gold currently depends on it. |
| A3 | **The quality gate does not gate.** Runs 43 and 44 were marked `success` and watermarks advanced while `quality_checks()` was reporting a failure. There is no severity (warning / reject / blocking). |
| A4 | **The daily forced run is silently lost.** `sidnl-pipeline-daily` fired at 18:36:10, returned in 0.02 s and left no `pipeline_run` row (0 rows with trigger `cron-daily`). It almost certainly hit the advisory lock held by the regular tick and returned `skipped`. Nothing retries it. |
| A5 | No retry limit or backoff. When bronze columns moved, six consecutive runs failed with the same error, spending 478 s of database time, and would have continued forever. |
| A6 | Logging is a single `steps` jsonb column on `pipeline_run`. There are no columns for source, inserted, updated, skipped, rejected or failed rows, `retry_count`, `failed_stage` or error text. `etl_run` is per brand only; nothing is logged per category. |
| A7 | One global transaction-level advisory lock (727100) covers the whole pipeline. It is safe and releases itself on failure, but brands and categories cannot run independently. |
| A8 | Incremental design: one watermark per bronze table plus a 5,000-row lookback. Late rows beyond the lookback and in-place corrections to old rows are not detected, because the shelf, search and observation tables have no `updated_at`. Only `platform_products` and `stores` have `last_seen_at`. |
| A9 | `v_pipeline_status` has 8 columns (last run, status, seconds, unmapped products, pending reviews, SI ids, multi-platform SI ids, failed runs in 24 h). Missing: last success vs last failure, rows processed, rejected rows, retry count, last error, next scheduled run. |

### Performance and storage

| # | Finding |
|---|---|
| P1 | `fact_shelf_position`: 627,894 updates against 570,136 live rows and 89,537 dead tuples (16%). The upsert rewrites every re-read row even when nothing changed. Guard it with `WHERE ... IS DISTINCT FROM`. |
| P2 | Index `ix_fsp_product_key` has 0 scans (5.8 MB) and the primary key 4 scans, while `source_record_id_key` has 3.2 M. Small, and the product_key index supports the FK delete path, so I recommend leaving them. |
| P3 | Storage grows with every shelf read (shelf history is kept). 688 MB today; on 2026-11-07 a load already failed with "no space left on device" at about 560 MB. A retention or archive rule is a business decision. |
| P4 | `fact_shelf_position` autovacuum is on defaults; with the update churn in P1 it needs table-level settings. |

### Git

Migrations 026-035 are now in `sql/silver/`. The live migration history also contains `silver_001b`, `001c`, `010_target_dims_facts`, `021b`, `021c`, `023a/b` and `silver_category_market_shelf` (20261106162817) that have no file with the same name in the repo. They may already be folded into the existing files; this needs a diff against the exported DB statements before anyone renumbers or overwrites anything.

## 5. Plan

All steps are versioned migrations numbered from 036, applied in order, none destructive. SI ids are never regenerated.

**036 Logging and state (minimum new structures).**
Add columns to `pipeline_run`: `pipeline_name`, `source_rows`, `inserted_rows`, `updated_rows`, `skipped_rows`, `rejected_rows`, `failed_rows`, `retry_count`, `failed_stage`, `error`. New small table `silver.pipeline_state` (per pipeline / category / brand: status, consecutive_failures, next_retry_at, last_error). New table `silver.dq_result` (run_id, check, severity, violations, detail).

**037 Cleaning (Safe items only).**
- F1/F2: run the existing product loader for the 11 Frozen Veg products, register `blue tribe foods` in `brand_scope` / `dim_brand` (disabled, untracked), relink the 42 rows. Accounts for all 42; none deleted.
- F6: fix `parse_pack` for `A + B` packs, add `total_content` correction and a `has_bonus_pack` flag; re-parse the 88 products. Raw `pack_raw` untouched.
- F7/F8: new `product_name_std` column (whitespace collapsed); variant `-` becomes NULL; empty `variant_key` becomes NULL. Raw `product_name` untouched.
- Add the missing `brand_key` foreign key on the fact tables after F2.

**038 Quality gate with severities.**
`quality_checks()` returns severity: *blocking* (SI id completeness, xref integrity, canonical uniqueness, FK integrity, duplicate facts, negative price/MRP, invalid stock state), *reject* (row-level violations such as price > MRP: kept out of metrics via `dq_status`, never deleted), *warning* (NULL optional fields, unlinked rows, stores without city). Blocking failures stop the watermark from advancing for the affected source. Results are stored in `dq_result`.

**039 Pipeline v2 (changes to `run_pipeline`).**
- Stage isolation: each category and brand runs in its own sub-transaction and is logged separately; one failure does not stop the others, but the run is marked `partial` and its watermark is not advanced.
- Retry: transient errors retry with backoff (proposal: 2, 4, 8, 16, 32 min, max 5 attempts); permanent errors (quality or schema) stop after the first failure and wait for a fix, instead of repeating every 3 minutes.
- Stale-run sweeper for runs that never finished.
- Daily run: if skipped for the lock, retry on the next tick until it runs once for the day.
- Lock stays a single advisory lock for the shared stages, with per-category advisory locks for category loads.
- Gold coupling per decision Q1.

**040 Health view.** `silver.v_silver_health` with every field you listed (last success, last failure, status, duration, rows processed, inserts and updates, rejects, DQ violations, unlinked count, retries, last error, next run from `cron.job`).

**041 Performance.** Guard the shelf upsert against no-op updates, set table-level autovacuum on `fact_shelf_position`, one-off `VACUUM` outside a transaction.

**Tests (phase 6), without any demo data.** Everything runs on real rows inside transactions that are rolled back: reprocess real bronze ranges for "new" and "updated" data, run twice for duplicates and reruns, inject a failure by calling a stage with an invalid argument or a temporarily revoked privilege, run two sessions for concurrency, and compare silver row counts and sums against bronze for reconciliation. Cross-platform mapping stays untestable until a second platform lands.

## 6. Decisions needed before phase 5

Q1. Gold coupling (A2). Options: (a) keep `gold.refresh_all` running as a separate step that never affects Silver's success status; (b) remove it from the Silver pipeline and give Gold its own job later. Recommendation: (a) now, so Mr Munchies gold keeps updating, and split it out in the Gold phase.
Q2. Approve the safe corrections in 037 (F1, F2, F6, F7, F8).
Q3. F9/F10: send Cherry / Cherry Flavoured (SI121, SI449) to the review queue, and keep the 34 empty-name products as they are until a second platform needs them?
Q4. Severity defaults in 038 as listed, in particular that a negative price blocks the load while price > MRP only rejects the row.
Q5. Retry policy numbers in 039.
Q6. Shelf history retention (P3): keep everything for now, or set a limit?
Q7. The 182 stores without a city and 14 products without a category stay NULL (cannot be derived from existing data). Confirm.
