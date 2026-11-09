-- APPLIED 2026-11-09 as dash_001_tables (version 20261109101147). Applied text = this logic, comments trimmed.
-- One table per app tab: overview, availability, pricing, visibility, ads, supply.
-- They replace the ~80 per-metric gold.metric_* tables for the dashboard. Nothing in gold is dropped here.
-- Rules:
--   * Product = sidnl_id only. Names, brand, category, size come from gold.dim_sidnl.
--     Store and city names come from gold.dim_store and gold.dim_city. Nothing descriptive is copied in.
--   * A metric lives in exactly one table. Other tabs join on (obs_date, platform, city_slug, sidnl_id).
--     Examples: Overview "Avail %" reads availability.osa_pct; Pricing "Sales" reads overview.net_sales.
--   * Every % column ships with its numerator and denominator counts, so category, city and brand roll-ups
--     are SUM(num) / SUM(den), never an average of percentages.
--   * Column names follow the dashboard / PDF metric names.
create schema if not exists dash;
comment on schema dash is 'Dashboard tables, one per app tab. Product key = sidnl_id; labels via gold.dim_* only.';

-- ── 1. OVERVIEW (/app/overview) ─────────────────────────────────────────────────────────────
-- KPIs GMV, Net Sales, Units Sold, Average Selling Price, Market Share, Contribution Margin.
-- Panels: Sales performance and Marketplace contribution (net_sales by platform).
-- Top & at-risk SKUs = this table + availability.osa_pct.
-- Source: platform sales reports. No feed is loaded yet, so the table stays empty until one is.
create table dash.overview (
  obs_date                 date not null,
  platform                 text not null,
  city_slug                text not null,
  sidnl_id                 text not null,
  gmv                      numeric(14,2),            -- Quantity sold x MRP
  net_sales                numeric(14,2),            -- after discounts / returns
  units_sold               bigint,
  avg_selling_price        numeric(12,2),            -- net_sales / units_sold
  category_sales           numeric(16,2),            -- market denominator for market share
  market_share_pct         numeric(7,3),             -- net_sales / category_sales x 100
  est_market_size          numeric(16,2),            -- net_sales / market share
  contribution_margin      numeric(14,2),
  contribution_margin_pct  numeric(7,2),
  refreshed_at             timestamptz not null default now(),
  primary key (obs_date, platform, city_slug, sidnl_id)
);

-- ── 2. AVAILABILITY (/app/availability/insights, /rca SKU x City, /visibility/dark-stores) ──
-- Two row types, told apart by store_key:
--   store_key IS NULL     -> SKU x city total (Category / SKU / City insights, RCA, Overview availability)
--   store_key IS NOT NULL -> one dark store (Dark Store Map pins, store popup, Stores to fix)
-- Counts on store rows are 0/1, so SUM(store rows) = the city row. Never sum both row types together.
-- Assortment = COUNT(DISTINCT sidnl_id) WHERE ds_listed_stores > 0.
-- Wt. OSA % = SUM(osa_pct x overview.net_sales) / SUM(overview.net_sales) when aggregating.
-- OSA D-1/D-2/D-3 = osa_pct of the 3 previous obs_date rows (not copied into extra columns).
create table dash.availability (
  obs_date                    date not null,
  platform                    text not null,
  city_slug                   text not null,
  sidnl_id                    text not null,
  store_key                   integer,
  ds_eligible_stores          integer not null default 0,  -- stores with a valid brand scan that day
  ds_listed_stores            integer not null default 0,
  ds_listing_pct              numeric(6,2),                -- DS Listing %
  osa_eligible_obs            integer not null default 0,  -- product-page stock checks
  osa_available_obs           integer not null default 0,
  osa_pct                     numeric(6,2),                -- OSA %
  osa_in_ls_eligible_obs      integer not null default 0,  -- checks where the SKU is listed
  osa_in_ls_available_obs     integer not null default 0,
  osa_in_ls_pct               numeric(6,2),                -- OSA % in LS
  in_stock_stores             integer not null default 0,  -- latest status of the day, any source
  out_of_stock_stores         integer not null default 0,  -- stock-out hotspots / SKUs affected
  low_stock_stores            integer not null default 0,  -- inventory_fe <= cfg low_stock_fe_units
  inventory_fe                bigint,                      -- Latest Inventory (FE), dark-store units
  inventory_fe_capped_stores  integer not null default 0,  -- platform shows a capped number
  inventory_be                bigint,                      -- Latest Inventory (BE): needs warehouse feed
  inventory_fe_be             bigint,                      -- FE + BE (NULL while BE is missing)
  drr                         numeric(12,2),               -- avg daily overview.units_sold, trailing 30 days
  doi_fe                      numeric(10,1),               -- inventory_fe / drr
  doi_be                      numeric(10,1),
  doi_fe_be                   numeric(10,1),
  is_critical                 boolean,                     -- osa_pct < cfg critical_osa_pct (city rows)
  priority                    text,                        -- High / Medium / Low from cfg OSA thresholds
  potential_sales_loss        numeric(14,2),               -- PSL proxy: out-of-stock stores x avg SP
  last_observed_at            timestamptz,
  refreshed_at                timestamptz not null default now()
);
create unique index availability_key on dash.availability (obs_date, platform, city_slug, sidnl_id, store_key) nulls not distinct;
create index availability_store on dash.availability (store_key, obs_date) where store_key is not null;

-- ── 3. PRICING (/app/pricing/insights, /app/pricing/price-parity) ───────────────────────────
-- Observed shelf prices per SKU x city x day. Sales, market share and ASP for the pricing
-- tables come from dash.overview via the join key.
-- Price Parity Score = 100 x share of rows with is_parity_break = false.
-- Competitor benchmarking = rows of other brands (dim_sidnl.brand_key) in the same category.
create table dash.pricing (
  obs_date                             date not null,
  platform                             text not null,
  city_slug                            text not null,
  sidnl_id                             text not null,
  stores_observed                      integer not null,
  mrp                                  numeric(12,2),
  selling_price                        numeric(12,2),   -- SP, average of store prices
  min_selling_price                    numeric(12,2),   -- City price comparison: Lowest
  max_selling_price                    numeric(12,2),   -- Highest
  discount_amount                      numeric(12,2),   -- MRP - SP
  discount_pct                         numeric(6,2),    -- (MRP - SP) / MRP x 100
  weighted_discount_pct                numeric(6,2),    -- SUM(MRP-SP)/SUM(MRP) over store readings
  price_per_100g                       numeric(12,2),   -- SP per 100 g (or 100 ml); NULL for pieces
  price_vs_national_pct                numeric(7,2),    -- city SP vs all-city SP, same platform
  price_gap_vs_lowest_marketplace_pct  numeric(7,2),    -- Cross-marketplace spread
  price_gap_vs_reference_pct           numeric(7,2),    -- vs cfg parity_reference_platform
  is_parity_break                      boolean,         -- |gap vs reference| > cfg parity_tolerance_pct
  threshold_sp                         numeric(12,2),   -- gold.cfg_sku threshold
  threshold_diff                       numeric(12,2),   -- SP - threshold
  sp_change_pct                        numeric(7,2),    -- vs previous obs_date: biggest increases / decreases
  discount_change_pts                  numeric(6,2),    -- Discount movement
  refreshed_at                         timestamptz not null default now(),
  primary key (obs_date, platform, city_slug, sidnl_id)
);

-- ── 4. VISIBILITY (/app/visibility, Keyword Tracking) ──────────────────────────────────────
-- search_type 'category': search_term = 'l1_id>l2_id' of a scoped category shelf.
--   Every brand is present, so SOV has a real market denominator.
-- search_type 'keyword': search_term = the search query. The scraper keeps only the searched
--   brand's cards, so rank columns are filled and SOV is NULL.
-- SOV % on a row = this SKU's share of the market (same date/platform/city/search_term).
-- Rows of one brand add up to the brand's SOV, which gives Brand-wise Share of Search.
-- "Top of search" = rank <= gold.cfg_threshold top_of_search_n (default 10, shown as Top 10 Placements).
-- Dark Store Map reads dash.availability store rows.
create table dash.visibility (
  obs_date                         date not null,
  platform                         text not null,
  city_slug                        text not null,
  search_type                      text not null check (search_type in ('category', 'keyword')),
  search_term                      text not null,
  sidnl_id                         text not null,
  stores_scanned                   integer not null,  -- stores where this shelf / query was read
  stores_listed                    integer not null,  -- stores where this SKU appeared
  listing_coverage_pct             numeric(6,2),      -- Listing Coverage
  impressions                      integer not null,  -- card appearances
  organic_impressions              integer not null,
  paid_impressions                 integer not null,
  top_of_search_impressions        integer not null,  -- Top 10 Placements
  top_of_search_organic_impressions integer not null,
  top_of_search_paid_impressions   integer not null,
  best_search_rank                 integer,
  avg_search_rank                  numeric(8,2),      -- Average Search Rank
  avg_organic_rank                 numeric(8,2),
  share_of_voice_pct               numeric(7,3),      -- Overall SOV / Share of Search
  organic_sov_pct                  numeric(7,3),
  paid_sov_pct                     numeric(7,3),
  top_of_search_sov_pct            numeric(7,3),
  top_of_search_organic_sov_pct    numeric(7,3),
  top_of_search_paid_sov_pct       numeric(7,3),
  refreshed_at                     timestamptz not null default now(),
  primary key (obs_date, platform, city_slug, search_type, search_term, sidnl_id)
);

-- ── 5. ADS (/app/ads/insights, /app/ads/keyword-search) ─────────────────────────────────────
-- One row = campaign x keyword x SKU per day. keyword and sidnl_id are NULL when the platform
-- reports that campaign only at a coarser level. report_level says which kind of row it is.
-- Sum KPIs over one report_level at a time.
-- Automations (rules, approvals, trigger history) are app state, not metrics, so they are not here.
-- Source: retail-media API / reports. No feed is loaded yet.
create table dash.ads (
  obs_date                 date not null,
  platform                 text not null,
  campaign_id              text not null,
  keyword                  text,
  sidnl_id                 text,
  report_level             text generated always as (
                             case when keyword is not null then 'keyword'
                                  when sidnl_id is not null then 'sku' else 'campaign' end) stored,
  campaign_name            text,
  campaign_type            text,
  campaign_status          text,
  is_campaign_on           boolean,                -- On/Off
  campaign_budget          numeric(14,2),
  budget_utilisation_pct   numeric(6,2),           -- Avg. BU (%), BU Trend = this over obs_date
  ad_spend                 numeric(14,2),
  impressions              bigint,
  clicks                   bigint,
  reach                    bigint,
  ctr_pct                  numeric(7,3),           -- clicks / impressions x 100
  cpc                      numeric(10,2),          -- ad_spend / clicks
  cpm                      numeric(10,2),          -- ad_spend / impressions x 1000
  direct_sales             numeric(14,2),
  indirect_sales           numeric(14,2),
  attributed_sales         numeric(14,2),          -- Total Sales = direct + indirect
  direct_roas              numeric(10,2),
  total_roas               numeric(10,2),          -- ROAS = attributed_sales / ad_spend
  aov                      numeric(12,2),
  new_users_acquired       bigint,
  direct_atc               bigint,
  indirect_atc             bigint,
  atc                      bigint,
  conversion_rate_pct      numeric(7,3),
  direct_qty_sold          bigint,
  indirect_qty_sold        bigint,
  total_qty_sold           bigint,
  most_viewed_position     integer,
  keyword_rank             integer,                -- Rank (keyword rows)
  kw_volume_monthly        bigint,                 -- KW VOL (platform supplied)
  keyword_opportunity      text,                   -- Scale these / Niche winners / Fix these / Deprioritise
  refreshed_at             timestamptz not null default now()
);
create unique index ads_key on dash.ads (obs_date, platform, campaign_id, keyword, sidnl_id) nulls not distinct;

-- ── 6. SUPPLY (/app/availability/purchase-orders, /invoices, /edi, RCA Warehouse & PO history) ─
-- One row = one PO line (PO x SKU), with its GRN, invoice, debit note and EDI status on the same row.
-- A line billed on several invoices gets one row per invoice_id.
-- FE/BE inventory, DRR and DOI for the PO ledger come from dash.availability (city row, same sidnl_id).
-- Source: marketplace vendor portal / ERP / EDI. No feed is loaded yet.
create table dash.supply (
  platform                  text not null,
  po_number                 text not null,
  sidnl_id                  text not null,
  invoice_id                text,
  warehouse_code            text,
  city_slug                 text,
  po_status                 text,                  -- Pending / Accepted / Partially fulfilled / Closed ...
  is_open                   boolean,               -- Open POs
  is_overdue                boolean,               -- Overdue POs
  priority                  text,
  is_critical_sku           boolean,               -- Critical SKUs (count per PO)
  potential_sales_loss      numeric(14,2),         -- PSL
  created_date              date,
  scheduled_date            date,
  expiry_date               date,
  grn_date                  date,
  po_units                  bigint,
  po_amount                 numeric(14,2),
  grn_units                 bigint,
  grn_amount                numeric(14,2),
  fulfilment_gap            bigint,                -- po_units - grn_units
  fill_rate_pct             numeric(6,2),          -- grn_units / po_units x 100 (roll up SUM/SUM)
  deficit_pct               numeric(6,2),
  delivery_time_days        integer,               -- grn_date - created_date
  delivery_delay_days       integer,               -- actual - scheduled (positive = late)
  scheduled_lead_time_days  integer,               -- scheduled_date - created_date
  invoice_date              date,
  invoice_qty               bigint,
  invoice_amount_incl_tax   numeric(14,2),
  invoice_status            text,
  due_date                  date,
  credit_days               integer,
  due_status                text,
  payment_date              date,
  payment_amount            numeric(14,2),
  advance_paid              numeric(14,2),
  tds_amount                numeric(14,2),
  approved_amount           numeric(14,2),
  amount_payable            numeric(14,2),
  grn_qty_diff              bigint,                -- invoice_qty - grn_units
  grn_amount_diff           numeric(14,2),         -- invoice amount - grn_amount (same tax basis)
  debit_note_id             text,
  dn_qty                    bigint,
  dn_amount_incl_tax        numeric(14,2),
  edi_document_code         text,                  -- EDI Monitor: Document / Code
  edi_direction             text,
  edi_partner               text,
  edi_received_at           timestamptz,
  edi_processed_at          timestamptz,
  edi_status                text,                  -- processed / failed / pending_ack
  edi_error_category        text,
  refreshed_at              timestamptz not null default now()
);
create unique index supply_key on dash.supply (platform, po_number, sidnl_id, invoice_id) nulls not distinct;

-- Same security posture as gold: RLS on, no policies, owner-only access.
alter table dash.overview     enable row level security;
alter table dash.availability enable row level security;
alter table dash.pricing      enable row level security;
alter table dash.visibility   enable row level security;
alter table dash.ads          enable row level security;
alter table dash.supply       enable row level security;
revoke all on schema dash from public;

-- New, unconfirmed threshold used for availability.low_stock_stores.
insert into gold.cfg_threshold (key, value, description, is_confirmed)
values ('low_stock_fe_units', 5, 'Dark store counts as low stock when FE units <= this (dash.availability.low_stock_stores).', false)
on conflict (key) do nothing;
