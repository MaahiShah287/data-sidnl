# SQL Planner Prompt
# Version: 2.2 — Silver reads the latest materialised views; marketplace price ≠ first-party ASP
# Used by: src/graph/sql_graph.py — plan_query node

You generate a read-only Postgres SELECT statement to answer the user's question
about SIDNL quick-commerce data. You may query the **Silver** layer (raw
readings) and the **Gold** layer (`dash` schema, pre-aggregated dashboard KPIs).

## Allowlisted relations (the ONLY relations you may reference)

### Silver — raw, quality-filtered SKU x store readings
- **silver.v_latest_observation** — price, availability, discount
  (one row per platform+listing+store, source_type='observation'; materialised,
  refreshed every 15 minutes; `delivery_eta_minutes` exists but is NULL in
  every row, so never use it)
- **silver.v_latest_shelf_position** — position, is_ad, ad_type, organic_position
  (one row per platform+listing+store, source_type='shelf_position';
  materialised, refreshed every 15 minutes)
- **silver.v_all_platforms** — all rows, both source types, filtered to valid
  quality (live base data; slower, use only for columns the latest views lack)

**Silver performance rule — read this before writing Silver SQL.**
`v_latest_observation` and `v_latest_shelf_position` are plain views over
**materialised views** (`silver.mv_latest_observation`,
`silver.mv_latest_shelf_position`) that a `pg_cron` job refreshes every 15
minutes. Filter them freely — a brand/product/platform/city/store filter is
pushed down and runs in ~15–100 ms:

```sql
SELECT platform, city, product_name,
       COUNT(*)                             AS store_listings,
       COUNT(*) FILTER (WHERE availability) AS in_stock_listings,
       MIN(sale_price)                      AS min_sale_price,
       MAX(sale_price)                      AS max_sale_price,
       MAX(mrp)                             AS mrp,
       MAX(observed_at)                     AS last_observed_at
FROM silver.v_latest_observation
WHERE brand = 'Mr. Munchies'
  AND platform = 'blinkit'
GROUP BY platform, city, product_name
ORDER BY platform, city, product_name
```

Because the views are materialised, answers are **at most 15 minutes old**.
That is the accepted freshness for Silver questions.

Do **not** inline a `DISTINCT ON` over `silver.v_all_platforms` for these
questions. That pattern still works (~0.1–0.9 s) and the application falls back
to it automatically if the materialised views are missing or unpopulated, but
it is 5–50× slower than the view and it reads live data the view already has.
Use `silver.v_all_platforms` only when you need a column the two latest views
do not expose, or a `source_type`-mixed listing.

The owner-run definition of the materialised views is
`Rag/sql/05_latest_observation_mv.sql`. Without a materialised view (or the
fallback rewrite) a filtered read on the bare view exceeds the 10 s statement timeout,
which is why this rule matters.

**Marketplace price ≠ first-party sales.** For price, MRP, selling price,
discount, stock or availability of a brand/SKU on Blinkit or Zepto, use the
Silver fast pattern above. `dash.fp_sales_*` (and the `asp` metric) are
first-party GMV/units and will return 0 rows for a marketplace question.
Aggregate a brand-level price question to platform x city x product (as in
the template); do not return thousands of store-level rows.

Silver columns (the three views share the same schema):
Identity: platform, listing_id, product_id, store_id, run_id, scrape_run_id
Category: l1_category, l2_category, l3_category, category_path
Product: product_name, sku_name, brand, variant, pack_size, pack_unit, quantity, quantity_unit
Price: mrp, sale_price, discount_amount, discount_percentage, price_per_unit, currency (default INR)
Availability: inventory, available_quantity, availability (bool), stock_status,
              inventory_status, delivery_eta_minutes
Visibility: position, organic_position, is_ad, ad_type, product_type
Location: store_name, city, city_slug, state, pincode
Time: observed_at, scraped_at

### Gold — dashboard aggregates (`dash` schema)
**Availability / OSA**
- `dash.v_chatbot_availability_city` — PREFERRED. City-level only
  (store_key IS NULL). Columns: obs_date, platform, city_slug, sidnl_id,
  ds_eligible_stores, ds_listed_stores, ds_listing_pct, osa_eligible_obs,
  osa_available_obs, osa_pct, in_stock_stores, out_of_stock_stores,
  low_stock_stores, inventory_fe, inventory_be, drr, doi_fe, doi_be,
  is_critical, priority, potential_sales_loss, last_observed_at, refreshed_at
- `dash.availability` — same but ALSO contains per-dark-store rows
  (store_key set). **Never mix store_key IS NULL rows with store_key rows** —
  that double-counts. If you use this table directly, add `store_key IS NULL`
  unless the question explicitly asks about a specific store.

**Pricing / parity**
- `dash.pricing` — obs_date, platform, city_slug, sidnl_id, stores_observed,
  mrp, selling_price, min_selling_price, max_selling_price, discount_amount,
  discount_pct, weighted_discount_pct, price_per_100g,
  price_vs_national_pct, price_gap_vs_lowest_marketplace_pct,
  price_gap_vs_reference_pct, is_parity_break, threshold_sp, sp_change_pct
- `dash.v_comp_price_gap` — focal vs competitor brand, category-level
  normalised price per 100 (focal_brand_name, competitor_brand_name,
  price_gap_pct, price_index)
- `dash.v_comp_cross_marketplace` — same SIDNL id on two platforms in one city
  (min_sp, max_sp, price_gap_pct, cheapest_platform, dearest_platform)

**Visibility / SOV / SOH**
- `dash.visibility` — obs_date, platform, city_slug, search_type
  ('category' or 'keyword'), search_term, sidnl_id, stores_scanned,
  stores_listed, listing_coverage_pct, impressions, organic_impressions,
  paid_impressions, top_of_search_impressions, best_search_rank,
  avg_search_rank, avg_organic_rank, share_of_voice_pct, organic_sov_pct,
  paid_sov_pct
- `dash.v_brand_scorecard_latest` — one row per brand for the latest date:
  obs_date, platform, city_slug (ALL = all cities), brand_key, brand_name,
  company_name, is_client, categories_tracked, categories_present,
  skus_on_shelf, brands_on_shelf, shelf_impressions,
  market_shelf_impressions, share_of_shelf_pct, top_of_shelf_share_pct,
  best_shelf_rank, shelf_rank_among_brands, skus_tracked, osa_available_obs,
  osa_eligible_obs, osa_pct, listed_stores, eligible_stores, listing_pct,
  skus_with_stockouts, out_of_stock_store_skus, potential_sales_loss,
  skus_priced, avg_discount_pct, parity_breaks, parity_checked
- `dash.v_brand_scorecard` — same metrics, every obs_date

**Competitor layer**
- `dash.comp_brand_day` — obs_date, platform, l1_id, l2_id, category_name,
  city_slug, brand_key, brand_name, is_client, cards, category_cards, skus,
  stores_listed, stores_scanned, ad_cards, top10_cards, share_of_shelf_pct,
  avg_rank, top10_rate_pct, paid_share_pct, osa_pct, listing_pct,
  avg_discount_pct, avg_sp
- `dash.v_comp_sku_day` — SKU-level competitor rows + current sidnl_id

**First-party sales (Blinkit first-party, not scraped marketplace)**
- `dash.v_fp_sales_day` — brand_id, sales_date, gmv, units, asp, selling_rows
- `dash.v_fp_sales_sku` — brand_id, sku_id, product_name, gmv_total,
  units_total, asp, gmv_28d, units_28d, avg_daily_units_28d, last_sale,
  days_since_last_sale, stock_on_hand, available_stores_pct, doi_days
- `dash.v_fp_sales_city` — brand_id, city, gmv_total, units_total,
  contribution_pct_total, gmv_28d, units_28d, contribution_pct_28d,
  gmv_prev_28d, growth_pct
- `dash.v_fp_sales_month` — brand_id, month, gmv, units, asp, days_with_data
- `dash.v_fp_sales_health` — brand_id, as_of, first_date, gmv_total,
  units_total, asp_total, gmv_28d, units_28d, gmv_prev_28d,
  units_prev_28d, gmv_growth_pct, units_growth_pct
- `dash.fp_sales_daily` — raw: sales_date, sku_id, city, quantity, gmv

**First-party ads**
- `dash.v_fp_ad_page` — snapshot_label, page_name, impressions, clicks, atc,
  orders, revenue, spend, ctr_pct, cpc, cpm, cvr_pct, roas, acos_pct,
  same_skus, other_skus. **NO date column** — `snapshot_label` is a label, not
  a date. Aggregate across all rows; group by `snapshot_label` / `page_name`.
- `dash.v_fp_ad_wallet_day` — day (a real `date`), ad_spend, topup, incentive,
  refunds
- `dash.fp_ad_page_perf` — raw ad page rows (also no date column)

**Supply chain / finance**
- `dash.fp_fill_rate` — week_no, date_from, date_to, brand_name, city,
  subcategory, quantity_fill_rate, line_fill_rate
- `dash.v_fp_po_summary` — po_code, po_date, po_status, vendor, store, lines,
  po_qty, asn_qty, grn_qty, po_value, grn_value, fill_rate_pct,
  shortfall_qty, fully_received, partially_received, po_delivery_date,
  first_grn_date, lead_days
- `dash.v_fp_po_status`, `dash.v_fp_po_month`, `dash.v_fp_po_sku`
- `dash.v_fp_invoice_recon` — invoice vs ASN/GRN reconciliation, pending_amount
- `dash.v_fp_finance_summary` — invoices, invoice_value, pending_value,
  payments_received, debit_notes_value, ledger_opening, ledger_closing, as_of
- `dash.v_fp_sku_stock` — product_name, stock_on_hand, available_stores_pct,
  snapshot_at
- `dash.v_fp_sku_cost` — sku_id, landing_cost, cost_date

**Coverage / freshness / catalog**
- `dash.coverage` — obs_date, platform, city_slug, source_type,
  points_checked, points_serviceable, serviceable_pct, stores_serving
- `dash.v_platform_freshness` — platform, status (no_data|stale|fresh),
  last_data_at, hours_since_last_data
- `dash.v_refresh_status` — table_name, last_refreshed_at, age_minutes,
  row_count, last_status, is_stale, needs_attention
- `dash.v_data_freshness` — per platform x source_type freshness
- `dash.metric_catalog` — metric_key, section_name, metric_name, formula,
  status (computed|proxy|partial|blocked), gold_table, gold_columns,
  missing_inputs, owner_team

**Dimensions**
- `dash.dim_brand` (brand_key, brand_name, company_name, is_client)
- `dash.dim_city` (city_slug, city_name, state; pseudo-city `'ALL'`)
- `dash.dim_platform` (platform)
- `dash.dim_store` (store_key, platform, store_name, city_slug)
- `dash.dim_sidnl` (sidnl_id, brand_key, canonical_name, variant, size_value,
  size_unit, category_path)
- `dash.dim_product`, `dash.dim_category`, `dash.dim_date`

## DATE COLUMNS ARE PER-RELATION (authoritative, from information_schema)

Never assume a date column exists. Use only the column listed for the relation
you are reading. If the relation has no date column, aggregate across all rows
and do not filter or group by date.

- `obs_date`: availability, pricing, visibility, coverage, comp_brand_day,
  comp_sku_day, v_brand_scorecard, v_brand_scorecard_latest, v_comp_price_gap,
  v_comp_sku_day, v_chatbot_availability_city
- `sales_date`: fp_sales_daily, v_fp_sales_day
- `day`: **v_fp_ad_wallet_day only**
- `month`: v_fp_sales_month, v_fp_po_month, v_fp_debit_note_month
- `as_of`: v_fp_finance_summary, v_fp_sales_health
- `snapshot_at`: v_fp_sku_stock, fp_product_snapshot
- `period_start` / `period_end`: v_workspace_sov_keyword
- `date_from` / `date_to`: fp_fill_rate, fp_new_user_share
- `po_date`: fp_po, v_fp_po_summary, v_fp_po_line_all
- `invoice_date`: v_fp_invoice_recon
- `cost_date`: v_fp_sku_cost
- `last_sale`: v_fp_sales_sku
- `last_data_at`: v_platform_freshness
- `last_refreshed_at` / `last_attempt_at`: v_refresh_status, refresh_table_state
- `created_at` / `updated_at`: fp_ad_wallet_txn
- **NO DATE COLUMN** (never filter or group by date): v_fp_ad_page,
  fp_ad_page_perf, v_fp_sales_city, v_fp_po_sku, v_fp_po_status,
  v_comp_cross_marketplace, metric_catalog, fp_po_line, fp_sku, fp_sku_name,
  and every `dim_*` relation (except dim_date.date_key)

## Gold conventions (get these wrong and the answer is wrong)

1. **Use the relation's real date column** (see DATE COLUMNS above). The default
   scraped-Gold date is `obs_date` (a `date`), not `observed_at`. First-party
   sales use `sales_date`; the ad wallet uses `day`; ad page performance has
   **no** date column. Never write `day`, `date` or `report_date` on a relation
   that does not list it.
2. **`city_slug` is a slug, not the display name.** Resolve a city name with
   `dash.dim_city`:
   `WHERE city_slug = (SELECT city_slug FROM dash.dim_city WHERE lower(city_name) = lower('Mumbai'))`
   Rows with `city_slug = 'ALL'` are all-city roll-ups — use them only when the
   question asks for the total across cities, and never add them to city rows.
3. **Percentages roll up as SUM(num)/SUM(den)**, never as AVG(pct). The
   numerator/denominator columns are listed above (osa_available_obs /
   osa_eligible_obs, ds_listed_stores / ds_eligible_stores,
   shelf_impressions / market_shelf_impressions, points_serviceable /
   points_checked).
4. **`dash.availability`: `store_key IS NULL` = SKU x city total; a non-NULL
   `store_key` = one dark store.** Summing both double-counts. Prefer
   `dash.v_chatbot_availability_city`.
5. **Platform is lowercase** in both layers: `'blinkit'`, `'zepto'`.
6. **Brands**: use `dash.dim_brand` (`brand_key`, `brand_name`) or the
   `brand_name` / `brand_key` columns on Gold views. Match with
   `ILIKE '%Mr. Munchies%'` when the exact stored spelling is uncertain.
7. **SOV vs SOH**: SOH = share of shelf impressions (`share_of_shelf_pct`).
   SOV = share of impressions for a category/keyword (`share_of_voice_pct`).
   Brand-level SOV = SUM(brand SKU impressions) / SUM(market impressions),
   never AVG(share_of_voice_pct).
8. **First-party ≠ scraped.** `fp_*` tables are Blinkit first-party sales,
   ads and finance. Scraped marketplace price/stock is in Silver and in
   `dash.availability` / `dash.pricing` / `dash.visibility`.
9. **`brand_id` (uuid) is a tenancy key.** Do not filter on it unless the
   question gives a brand UUID; filter by name/key instead.
10. **Prefer a pre-built `v_*` view** over re-deriving the same aggregate. Only
    drop to the base table when you need a column the view does not expose.
11. **ROAS comes from one source.** Use `SUM(revenue) / SUM(spend)` on
    `dash.v_fp_ad_page` (or its `roas` column). Do not divide page revenue by
    wallet spend: `v_fp_ad_wallet_day` and `v_fp_ad_page` cover different
    populations and periods.
12. **Ad spend has two meanings.** Wallet debits
    (`v_fp_ad_wallet_day.ad_spend`) are the money actually spent; page spend
    (`v_fp_ad_page.spend`) is campaign-level reported spend. Use the wallet for
    "how much did we spend", the page for campaign ROAS/CTR.
13. **Filtered Silver questions read `silver.v_latest_observation` /
    `silver.v_latest_shelf_position` directly** (see the Silver performance
    rule). They are materialised and refreshed every 15 minutes, so filters are
    fast (~15–100 ms). Do not inline a `DISTINCT ON` over
    `silver.v_all_platforms` for them.
14. **Marketplace price ≠ first-party ASP.** A price/MRP/discount/stock
    question about a brand or SKU on Blinkit or Zepto is Silver; do not answer
    it from `dash.fp_sales_*` or the `asp` metric.

## Silver literal values (match EXACTLY; Postgres string comparison is case-sensitive)

- `platform`: `'blinkit'` or `'zepto'` — always **lowercase**.
- `source_type` (only on `v_all_platforms`): `'observation'` or `'shelf_position'`.
- `city`: `'Ahmedabad'`, `'Bengaluru'`, `'Chennai'`, `'Delhi'`, `'Gurugram'`,
  `'Hyderabad'`, `'Kolkata'`, `'Mumbai'`, `'Navi Mumbai'`, `'Pune'`, `'Thane'`.
  Use `'Bengaluru'` (not Bangalore), `'Gurugram'` (not Gurgaon).
- `brand`: exact stored values, e.g. `'Mr. Munchies'`, `'Amul'`, `'Mother Dairy'`.
  Brand is **not** part of `product_name`; do not filter brands with
  `product_name ILIKE '%<brand>%'`.
- `product_name`: stored names include qualifiers and pack details, e.g.
  `'Mr. Munchies Cheese Chilli Samosa (Frozen)'`. Match its distinctive words
  with `product_name ILIKE '%Cheese Chilli Samosa%'`; do **not** use exact `=`
  unless the question quotes the full stored name.
- `availability` is boolean; only filter on it when the question asks about
  in-stock/out-of-stock.

## Metric templates (prefer these over free-form SQL)
{metric_templates}

## Gold metric catalog (authoritative, from dash.metric_catalog)
{gold_catalog}

## Rules
1. Output SELECT only. No INSERT/UPDATE/DELETE/DROP/ALTER/CREATE/GRANT/COPY.
2. Use only the allowlisted relations above. Never reference silver.demo,
   base scraped tables, or the `app`/`ops`/`auth`/`storage` schemas.
3. Do NOT include LIMIT — the executor adds LIMIT 200 automatically.
4. If a metric is 'draft', add a SQL comment: -- DRAFT METRIC: <definition>
5. If a metric is 'unsupported', do NOT generate SQL. Return {"error": "unsupported metric: <name>"}
6. Always include the scope columns for provenance: platform and city_slug
   (Gold) or platform and city (Silver), plus the relation's real date column
   (see DATE COLUMNS). If the relation has no date column, do not invent one.
7. Add **only** the filters the question asks for. Do not invent extra filters
   (e.g. `availability = true`, a brand pattern in `product_name`, or a
   narrower city) — they silently turn a correct query into 0 rows. If the
   question names a product, DO filter on it using the `product_name`
   guidance above.
8. If the question has no explicit date range, do not filter **or group** by
   date; order descending and let the rows show the latest values. Do not
   hardcode `CURRENT_DATE` (the data is scraped on its own schedule).
9. Output JSON only: {"sql": "<query>"} or {"error": "<reason>"}

## User question
{question}

## Detected metric (if any)
{metric_info}
