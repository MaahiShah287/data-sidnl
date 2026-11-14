# Gold (dash) layer — what it is and how to read it

The SIDNL data platform has **two queryable layers**. The chatbot queries both;
it is not restricted to Silver.

## Silver layer

Raw, quality-filtered **SKU × store readings** collected by the scrapers:
price (MRP, selling price, discount), availability/inventory, shelf position,
ad placement. One row per platform × listing × store per scrape. Silver answers
"what is the price / stock / shelf position of this specific SKU at this store
or in this city, right now". The chatbot reads it through three views:
`silver.v_latest_observation`, `silver.v_latest_shelf_position` and
`silver.v_all_platforms`.

## Gold layer

The **`dash` schema**: pre-aggregated dashboard tables and views built from
Silver by the Gold refresh (`silver.run_gold_pending()`). Gold answers anything
that sounds like a KPI — sales, OSA, share of shelf, price parity, ROAS, fill
rate, pending invoices. Use Gold for trends and totals; use Silver when you need
the individual reading.

## `dash.metric_catalog` is authoritative

`dash.metric_catalog` lists every dashboard metric with its `formula`, `status`
(`computed`, `proxy`, `partial`, `blocked`), `gold_table`, `gold_columns`,
`missing_inputs` and `owner_team`. When the catalog and this document disagree,
the catalog wins. A `proxy` metric is a stand-in formula; `partial` means the
table exists but its inputs are incomplete; `blocked` means it cannot be
computed from scraped data.

## Availability and OSA

On-shelf availability (OSA) = `osa_available_obs / osa_eligible_obs`. Listing
percentage = `ds_listed_stores / ds_eligible_stores`. Both live in
`dash.availability` at SKU × city × day grain. **`store_key IS NULL` marks the
city total; a non-NULL `store_key` marks one dark store.** Never sum both row
types together — that double-counts every observation. The chatbot uses
`dash.v_chatbot_availability_city`, which only exposes city-total rows.

## Share of Shelf (SOH) versus Share of Voice (SOV)

These are different metrics and must not be used interchangeably.

**Share of Shelf (SOH)** is the brand's share of **shelf impressions** in a
category: `shelf_impressions / market_shelf_impressions`, exposed as
`share_of_shelf_pct` on `dash.v_brand_scorecard` and
`dash.v_brand_scorecard_latest`. It measures how much physical/digital shelf
space the brand occupies.

**Share of Voice (SOV)** is the SKU's share of **search or category
impressions** for a category shelf or keyword: `share_of_voice_pct` on
`dash.visibility`. Brand SOV is the SUM of the brand's SKU impressions divided
by the market total for the same market — never an average of the percentage
column. Campaign keyword SOV is in `dash.v_workspace_sov_keyword`.

## Percentages always roll up as SUM(numerator) / SUM(denominator)

Gold stores the numerator and denominator next to every percentage (OSA,
listing, SOH, serviceability, fill rate). Rolling a percentage up over days or
cities with `AVG(pct)` gives the wrong answer because each day has a different
denominator. Always `SUM(num) / SUM(den)`. This applies to Silver in-stock rate
too, which is why the dictionary keeps the counts.

## Pricing, discount and price parity

`dash.pricing` holds observed MRP, selling price and discount per SKU × city ×
day, plus parity columns: `price_vs_national_pct`,
`price_gap_vs_lowest_marketplace_pct`, `price_gap_vs_reference_pct` and the
boolean `is_parity_break`. A positive gap versus the lowest marketplace means
SIDNL is dearer than the cheapest competitor. `weighted_discount_pct` is the
GMV-weighted discount; `discount_pct` is the per-row value.
`dash.v_comp_cross_marketplace` compares the same SIDNL id on two platforms in
one city (`price_gap_pct = (max_sp - min_sp) / min_sp`).

## First-party sales, ads and finance

Tables prefixed `fp_` are **Blinkit first-party** data from the brand portal,
not scraped marketplace data.

- **GMV** = sum of `dash.fp_sales_daily.gmv`; **units** = sum of `quantity`;
  **ASP** = GMV / units. Roll-ups live in `dash.v_fp_sales_day`,
  `dash.v_fp_sales_sku`, `dash.v_fp_sales_city`, `dash.v_fp_sales_month` and
  `dash.v_fp_sales_health` (28-day vs prior 28-day growth).
- **Ad performance** (`dash.v_fp_ad_page`): impressions, clicks, orders,
  revenue, spend and derived CTR, CPC, CPM, CVR, **ROAS = revenue / spend**,
  ACOS. Wallet debits (the money actually spent) are in
  `dash.v_fp_ad_wallet_day`.
- **Supply chain / finance**: `dash.fp_fill_rate` (weekly quantity and line fill
  rate), `dash.v_fp_po_summary` (PO vs GRN, shortfall, lead time),
  `dash.v_fp_finance_summary` (invoice value, pending value, payments, ledger)
  and `dash.v_fp_invoice_recon` (invoice vs ASN/GRN).

## Serviceability is not stock

`dash.coverage` measures whether a pincode is **serviceable**
(`points_serviceable / points_checked`) per day × platform × city × source. A
non-serviceable pincode is not the same as an out-of-stock SKU. Never describe
coverage as availability.

## Dates, cities and platforms in Gold

The Gold date column is `obs_date` (`sales_date` for first-party sales, `day`
for the ad wallet, `as_of` for summaries). `city_slug` is a slug, not the
display name; resolve it through `dash.dim_city`. The pseudo-city `'ALL'` is an
all-city roll-up — use it only for totals and never add it to individual city
rows. Platform values are lowercase: `'blinkit'` and `'zepto'`.

## Data freshness

`dash.v_platform_freshness` reports `no_data` / `stale` / `fresh` per platform.
`dash.v_refresh_status` reports the last successful refresh per Gold table,
`age_minutes`, `is_stale` and `needs_attention`. Quote freshness when a number
looks unexpectedly old rather than assuming the pipeline failed.

## What is genuinely unavailable

- **Delivery ETA** — `delivery_eta_minutes` exists in Silver but is NULL in
  every row, and no Gold table computes it.
- **Instamart and JioMart** — there are no rows for those platforms in Silver or
  Gold.
- **Industry market share / total category size** — SIDNL only observes the
  tracked quick-commerce shelf; there is no category-size or competitor-revenue
  input. Share of Shelf and Share of Voice are available and are not the same
  thing as industry market share.
