# SIDNL Data Profile Report

_Generated: 2026-11-09 10:54 UTC_

> **Hard rule**: silver.demo is excluded from every query in this report.

## 1. Row Counts

### 1a. Raw base-table counts (per platform, per source_type)

| platform | source_type | raw_rows |
| ---|---|--- |
| blinkit | observation | 7,370 |
| blinkit | shelf_position | 48,535 |
| zepto | shelf_position | 344 |


### 1b. View counts (deduplicated / filtered)


**v_all_platforms**

| platform | rows |
| ---|--- |
| blinkit | 55,905 |
| zepto | 344 |


**v_latest_observation**

| platform | rows |
| ---|--- |
| blinkit | 5,055 |


**v_latest_shelf_position**

| platform | rows |
| ---|--- |
| blinkit | 33,647 |
| zepto | 344 |


## 2. Distinct Values for Key Categorical Columns


### scrape_status

| platform | value | count |
| ---|---|--- |
| blinkit | None | 48,191 |
| blinkit | 'ok' | 7,714 |
| zepto | 'ok' | 344 |


### scrape_run_status

| platform | value | count |
| ---|---|--- |
| blinkit | None | 55,905 |
| zepto | None | 344 |


### data_quality_status

| platform | value | count |
| ---|---|--- |
| blinkit | 'valid' | 55,905 |
| zepto | 'valid' | 344 |


### stock_status

| platform | value | count |
| ---|---|--- |
| blinkit | 'in_stock' | 34,600 |
| blinkit | 'out_of_stock' | 21,305 |
| zepto | 'in_stock' | 330 |
| zepto | 'out_of_stock' | 14 |


### inventory_status

| platform | value | count |
| ---|---|--- |
| blinkit | 'exact' | 55,519 |
| blinkit | 'capped' | 386 |
| zepto | 'exact' | 344 |


### ad_type

| platform | value | count |
| ---|---|--- |
| blinkit | None | 55,624 |
| blinkit | 'monet_product_listing' | 281 |
| zepto | None | 344 |


### product_type

| platform | value | count |
| ---|---|--- |
| blinkit | 'Dark Chocolate Bar' | 12,076 |
| blinkit | 'Milk Chocolate Bar' | 7,617 |
| blinkit | 'Soya Chaap' | 6,648 |
| blinkit | 'Samosa' | 6,541 |
| blinkit | 'Veg Burger Patty' | 2,769 |
| blinkit | 'Cheese Nuggets' | 2,605 |
| blinkit | 'Spring Roll' | 2,025 |
| blinkit | 'Pizza' | 1,801 |
| blinkit | 'French Fries' | 1,776 |
| blinkit | 'Nuggets' | 1,706 |
| blinkit | 'Paratha' | 1,623 |
| blinkit | 'Compound Chocolate Bar' | 1,586 |
| blinkit | 'Frozen Paneer Bites' | 1,133 |
| blinkit | 'Aloo Tikki' | 868 |
| blinkit | 'Potato Bites' | 854 |
| blinkit | 'Veggie Fingers' | 849 |
| blinkit | 'Veg Kebab' | 845 |
| blinkit | 'Milk Chocolate Pack' | 804 |
| blinkit | 'Pizza Pocket' | 753 |
| blinkit | 'Shrikhand' | 384 |
| blinkit | 'Peda' | 128 |
| blinkit | 'Rabri' | 93 |
| blinkit | 'Kaju Katli' | 64 |
| blinkit | 'Milk Cake' | 60 |
| blinkit | 'Kheer' | 58 |
| blinkit | 'Ras Malai' | 51 |
| blinkit | 'Amrakhand' | 42 |
| blinkit | 'Laddu' | 39 |
| blinkit | 'Rasgulla' | 35 |
| blinkit | 'Gulab Jamun' | 35 |
| blinkit | 'Sweets' | 21 |
| blinkit | 'Salted Butter' | 6 |
| blinkit | 'Cow Ghee' | 4 |
| blinkit | 'Ghee' | 2 |
| blinkit | 'Modak' | 2 |
| blinkit | 'Fresh Cream' | 2 |
| zepto | None | 344 |


## 3. NULL % Per Platform

| platform | source_type | total | null_listing_id% | null_store_id% | null_availability% | null_sale_price% | null_mrp% | null_discount_percentage% | null_position% | null_organic_position% | null_is_ad% | null_brand% | null_city% |
| ---|---|---|---|---|---|---|---|---|---|---|---|---|--- |
| blinkit | observation | 7,370 | 0.0 | 0.0 | 0.0 | 30.9 | 30.9 | 30.9 | 100.0 | 100.0 | 100.0 | 0.0 | 0.0 |
| blinkit | shelf_position | 48,535 | 78.7 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.6 | 0.0 | 0.0 | 0.3 |
| zepto | shelf_position | 344 | 100.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 5.8 |


## 4. Temporal Coverage and Dimension Counts


### 4a. observed_at range

| platform | source_type | earliest | latest | total_rows |
| ---|---|---|---|--- |
| blinkit | observation | 2026-10-26 06:59:11.743207+00:00 | 2026-11-08 06:32:17.364317+00:00 | 7,370 |
| blinkit | shelf_position | 2026-10-29 01:57:17.047055+00:00 | 2026-11-09 06:33:08.270626+00:00 | 48,535 |
| zepto | shelf_position | 2026-11-08 06:35:07.949769+00:00 | 2026-11-08 06:49:16.995718+00:00 | 344 |


### 4b. Distinct cities, stores, brands, L1/L2

| platform | cities | stores | brands | L1 categories | L2 categories |
| ---|---|---|---|---|--- |
| blinkit | 11 | 934 | 3 | 2 | 3 |
| zepto | 1 | 8 | 1 | 0 | 0 |


## 5. Cross Source-Type Overlap

> Non-zero `overlap_count` means the same (platform, listing_id, store_id) has BOTH observation and shelf_position rows. The hard rule says these must not be mixed silently.

| platform | overlap_count | obs_only | shelf_only |
| ---|---|---|--- |
| blinkit | 1,231 | 3,824 | 32,416 |
| zepto | 0 | 0 | 344 |


## 6. Duplicate source_record_id

| platform | source_type | distinct_dup_ids | excess_rows |
| ---|---|---|--- |
| blinkit | shelf_position | 195 | 195 |


## 7. Sanity Flags

> `null_avail_pct > 20` triggers a data-quality warning.

| platform | source_type | total | sale>mrp | neg_prices | bad_disc% | null_avail% |
| ---|---|---|---|---|---|--- |
| blinkit | observation | 7,370 | 0 | 0 | 0 | 0.0 |
| blinkit | shelf_position | 48,535 | 0 | 0 | 0 | 0.0 |
| zepto | shelf_position | 344 | 0 | 0 | 0 | 0.0 |


## 8. Recommended View Filters


### scrape_status
- **blinkit**: dominant values → 'ok' (7,714 rows, 13.8%); 48,191 NULL rows
- **zepto**: dominant values → 'ok' (344 rows, 100.0%)

### scrape_run_status
- **blinkit**: dominant values → (all null); 55,905 NULL rows
- **zepto**: dominant values → (all null); 344 NULL rows

> **Action**: Replace the `TODO(diagnostics)` stubs in `sql/01_views.sql` with:
> ```sql
> AND scrape_status IN (<dominant non-null scrape_status values above>)
> AND scrape_run_status IN (<dominant non-null scrape_run_status values above>)
> ```
> Review NULL rows separately — a NULL scrape_status may indicate a scraper bug rather than a valid record.
