# `dash` — six dashboard tables

## Status (2026-11-09)
| Migration | Live version | md5 of applied text | State |
|---|---|---|---|
| `dash_001_tables` | `20261109101147` | `19ae83789206b32cd3d674652cb5bd4b` | **APPLIED** |
| `dash_002_refresh` | `20261109101249` | `86b78e1a66d80a7f1f67721677b91387` | **APPLIED**. First full `dash.refresh(null)` ran at 10:12 UTC. |
| `dash_003_schedule` | `20261109101525` | `cf8cfeea1b0a38ad98ad54e00c8e4471` | **APPLIED**. `silver.run_gold_pending()` now calls `dash.refresh(3)` after every gold refresh; errors go to `gold_stage.refresh_state` key `dash_last_error`. |

The SQL that was applied is the same logic as `001_dash_tables.sql` / `002_dash_refresh.sql`, with shorter comments and a `comment on table` added per table. The exact applied text is in `supabase_migrations.schema_migrations`; export it with `../silver/ledger_verify.sql`.
Tables refresh automatically after each successful gold refresh. For a manual full rebuild (~50 s), run `select dash.refresh(null);`.

One table per app tab, replacing the ~80 `gold.metric_*` tables as the thing the dashboard reads. Nothing in `gold` is dropped.

| Table | App pages | Grain (primary key) | Filled today? |
|---|---|---|---|
| `dash.overview` | Overview | obs_date · platform · city_slug · sidnl_id | **No.** Needs a sales feed. |
| `dash.availability` | Availability Insights, RCA (SKU×City), Dark Store Map, Overview availability | obs_date · platform · city_slug · sidnl_id · store_key (NULL = city total) | **Yes**: 1,312 city rows + 49,292 store rows |
| `dash.pricing` | Pricing Overview, Price Parity | obs_date · platform · city_slug · sidnl_id | **Yes**: 1,252 rows |
| `dash.visibility` | Visibility, Keyword Tracking | obs_date · platform · city_slug · search_type · search_term · sidnl_id | **Yes**: 29,919 category + 363 keyword rows |
| `dash.ads` | Ads Insights, Keyword Search | obs_date · platform · campaign_id · keyword · sidnl_id | **No.** Needs a retail-media feed. |
| `dash.supply` | Purchase Orders, Invoices, EDI Monitor, RCA Warehouse / PO history | platform · po_number · sidnl_id · invoice_id | **No.** Needs a vendor-portal / ERP / EDI feed. |

## Rules
- **Product = `sidnl_id`.** Product name, brand, category and size come only from `gold.dim_sidnl`; store and city names from `gold.dim_store` / `gold.dim_city`; category names from `gold.dim_category`. No table repeats them.
- **Each metric is stored once.** Other tabs join on `(obs_date, platform, city_slug, sidnl_id)`. For example, Pricing "Sales" = `overview.net_sales` and Overview "Avail %" = `availability.osa_pct`.
- **Every % column comes with its numerator and denominator.** Roll-ups to category, city or brand are `SUM(num) / SUM(den) × 100`, never `AVG(pct)`.
- **`availability` has two row types.** Use `store_key IS NULL` rows for SKU×city tables and `store_key IS NOT NULL` rows for the map. Never sum both together.

## Feature → column map

### Overview
| Feature | Column(s) |
|---|---|
| GMV · Net Sales · Units Sold · Average Selling Price · Market Share · Contribution Margin | `overview.gmv`, `net_sales`, `units_sold`, `avg_selling_price`, `market_share_pct`, `contribution_margin` (+ `_pct`) |
| Sales performance (Daily/Weekly/Monthly) | `overview.gmv`, `net_sales` by `obs_date` |
| Marketplace contribution | `overview.net_sales` by `platform` ÷ total |
| Advertisement performance · Marketing pulse | `ads.ad_spend`, `attributed_sales`, `total_roas`, count of campaigns |
| Availability & stock-outs | `availability.osa_pct` (gauge), `out_of_stock_stores` (hotspots), count of SKUs with `out_of_stock_stores > 0` |
| City performance | `availability.osa_pct` by city + `gold.dim_city.state`; `overview.net_sales` share |
| Finance pulse (Discrepancies / Outstanding) | `supply.grn_amount_diff`, `supply.amount_payable` |
| Top & at-risk SKUs | `overview.net_sales`, `units_sold`; `availability.osa_pct`; trend = `net_sales` over dates |

### Availability Insights / RCA
| Feature | Column(s) |
|---|---|
| Assortment | `COUNT(DISTINCT sidnl_id) WHERE ds_listed_stores > 0` |
| DS Listing % | `ds_listed_stores / ds_eligible_stores` (`ds_listing_pct` on the row) |
| OSA % · Avg OSA % | `osa_available_obs / osa_eligible_obs` (`osa_pct`) |
| OSA % in LS | `osa_in_ls_available_obs / osa_in_ls_eligible_obs` (`osa_in_ls_pct`) |
| Wt. OSA % · Wt. OSA % in LS | `SUM(osa_pct × overview.net_sales) / SUM(net_sales)` |
| Latest Inventory FE / BE / FE+BE | `inventory_fe`, `inventory_be`, `inventory_fe_be` |
| DRR · DOI FE / BE / FE+BE | `drr`, `doi_fe`, `doi_be`, `doi_fe_be` (fill once `overview.units_sold` exists) |
| Sales (MRP) · Quantity Sold · Est. Market Share / Size | `overview.gmv`, `units_sold`, `market_share_pct`, `est_market_size` |
| MRP · SP · Discount (SKU insights) | `pricing.mrp`, `selling_price`, `discount_pct` |
| Competitor drawer (Brands / SKUs) | same columns grouped by `dim_sidnl.brand_key`; Overall SOV = `visibility.share_of_voice_pct` |
| RCA SKU×City: OSA D-1 / D-2 / D-3 · Inventory (FE) · Impact | `osa_pct` of the three previous `obs_date`s; `inventory_fe`; `potential_sales_loss` |
| Critical issues · priority | `is_critical`, `priority` (thresholds in `gold.cfg_threshold`) |
| Dark Store Map: % in stock, affected / low-stock SKUs, listed / not listed, last updated | store rows: `in_stock_stores`, `out_of_stock_stores`, `low_stock_stores`, `ds_listed_stores`, `last_observed_at` |

### Pricing Overview / Price Parity
| Feature | Column(s) |
|---|---|
| Average Selling Price · Average Discount % | `pricing.selling_price`, `discount_pct` (`weighted_discount_pct` = MRP-weighted) |
| Weighted Price per Unit · Price / 100g | `price_per_100g` (g and ml packs; 92% of rows filled) |
| MRP and selling price · Discount movement | `mrp`, `selling_price`, `discount_change_pts` over dates |
| Biggest price increases / decreases | `sp_change_pct` |
| City insights: ASP · Discount · Pricing · Vs national | `selling_price`, `discount_pct`, `price_vs_national_pct` |
| City price comparison: Avg SP · Lowest · Highest | `selling_price`, `min_selling_price`, `max_selling_price` |
| Cross-marketplace: Spread, per-marketplace MRP / SP / Disc | rows of the same `sidnl_id` per `platform`; `price_gap_vs_lowest_marketplace_pct` |
| Price Parity Score · Parity alerts | `100 × share of rows with is_parity_break = false`; `price_gap_vs_reference_pct` |
| Threshold | `threshold_sp`, `threshold_diff` (from `gold.cfg_sku`) |
| Sales · Market Share · Market Size | from `overview` |
| Competitor benchmarking | rows of other brands in the same category |

### Visibility
| Feature | Column(s) |
|---|---|
| Average Search Rank | `avg_search_rank` (`best_search_rank`, `avg_organic_rank`) |
| Share of Search · Share of Voice · Brand-wise Share of Search | `share_of_voice_pct` (sum across a brand's SKUs = brand SOV); `organic_sov_pct`, `paid_sov_pct` |
| Top 10 Placements | `top_of_search_impressions` (+ `_sov_pct`, organic / paid splits) |
| Listing Coverage | `stores_listed / stores_scanned` (`listing_coverage_pct`) |
| Keyword Tracking: Your Rank · Δ Rank | `search_type = 'keyword'` rows: `avg_search_rank`, change vs previous date |

### Ads Insights / Keyword Search
All of the Campaign Insights columns are in `dash.ads`, from On/Off through Total Qty Sold. The table also holds the keyword-table columns (spend, sales, impressions, clicks, CTR, conversion, CPC, ROAS, rank, opportunity) and KW volume.

### Purchase Orders / Invoices / EDI
All PO-ledger, invoice and EDI columns are in `dash.supply`. Ledger inventory, DRR and DOI come from `availability`.

## Not covered by these six tables (on purpose)
- **Automations (rules, approvals, trigger history), Alerts (acknowledge/snooze), Team, Settings, Integrations.** These are application state, not metrics, so they belong in the app's own tables.
- **Competitor "Gap ₹ / Gap %" for one of our SKUs against a named competitor product.** This needs a competitor-pairing list that doesn't exist yet. Category-level benchmarking works today.
- **Missing listing attributes / listing health.** These are product attributes; read them from `silver.dim_product`.

## Data limits today
- Only Blinkit has meaningful volume (Zepto has a few hundred readings), so cross-marketplace parity rows are 0 until the same SI id is priced on two platforms in the same city on the same day.
- Keyword search stores only the searched brand's cards, so keyword SOV is NULL. Category shelves carry every brand and give a real SOV.
- `gold.dim_sidnl` can lag silver by one gold run. `003` runs `dash.refresh` right after the gold refresh so new SI ids resolve.

## Files
| File | What |
|---|---|
| `001_dash_tables.sql` | schema + 6 tables + RLS + one unconfirmed threshold (`low_stock_fe_units = 5`) |
| `002_dash_refresh.sql` | `dash.refresh(p_visibility_days)` |
| `003_dash_schedule.sql` | adds `dash.refresh(3)` to `silver.run_gold_pending()` (isolated: a failure never fails gold) |
| `003_rollback.sql`, `001_002_rollback.sql` | rollbacks, in that order |

## Dry run on live (2026-11-09, inside a transaction that was rolled back)
Full refresh took **48 s**; the per-run `refresh(3)` only rebuilds the last 3 days of visibility.
- OSA: 7,370 obs and 14.288% in both dash and `gold.osa_daily`.
- Pricing: 1,252 rows in both dash and `gold.price_daily`.
- Store rows sum exactly to city rows (0 mismatches).
- Every category market's SOV sums to 99.84–100.07% (rounding).
- Brand SOV rebuilt from dash rows matches `gold.visibility_daily` within 0.022 points.
