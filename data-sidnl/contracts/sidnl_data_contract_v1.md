# SIDNL Data Contract v1 (all data)

Nov 11, 2026 · @dev · For: DataEng (Upen), Scraping (Praptee), Backend (Atharva)

This is the rulebook for **every** feed into SIDNL: scraped platform data, first-party
portal exports, and (reserved) sales and inventory feeds. The ads-only detail lives in
`contracts/fp_ads_data_contract_v1.md`; this document covers the whole system and points
to it for ads specifics.

## 1. What this contract is

- **Producers:**
  - *Scraping* writes platform observations (one adapter per platform; Blinkit live today,
    Zepto/Instamart/Jiomart tables reserved).
  - *First-party* — a human downloads seller-portal Excel exports into `first_party/`
    (git-ignored; company files are never committed) and `scripts/load_first_party.py`
    parses them.
- **Consumer:** Data Engineering. Bronze (raw, append-only) → silver (clean, typed,
  append-only) → dash (metric tables, atomically rebuilt).
- **Reader:** Backend's FastAPI reads **dash tables and views only** — never bronze,
  silver, or ops.
- Not the parsers/loader: they are code that enforces this contract. This document is
  what they enforce.

Core principles (non-negotiable):

1. **Append-only above dash.** Bronze and silver never delete or update rows; every row
   keeps `loaded_at`. Corrections are new rows or flags, decided by the team first.
2. **Nothing is deleted without asking.** Dates and timestamps are sacred; dash tables
   are the only layer rebuilt (delete+insert in one transaction), always regenerable from
   bronze.
3. **Bad data is flagged, not silently fixed.** `dq_status` on every fact row.
4. **The API is read-only.** No write path from the frontend to the database.

## 2. Rules that apply to every field

| Topic | Rule |
|---|---|
| Names | snake_case, English, no abbreviations except `id`, `sku`, `mrp`, `url`, `cpm`, `roas`, `sov`, `atc`, `osa`, `gmv`, `doi`, `grn`, `po` |
| Platform IDs | Always text, even when they look numeric (`campaign_id = "284970"`) |
| Our IDs | `sidnl_id` is our canonical SKU key (see §7); deterministic — a replay produces the same mapping |
| Time | `observed_at`/`loaded_at` are UTC `timestamptz`. `obs_date` is the IST business date (`observed_at at time zone 'Asia/Kolkata'::date`, a generated column in silver). IST only on screen |
| Money | Rupees, `numeric`. Never paise, never float |
| Rates | Percent 0–100 as `numeric(6,2)`/`(7,3)`; RoAS as a ratio |
| Counts | Whole numbers (`bigint`/`integer`); text that must be a number is coerced and flagged |
| Empty | `null` = "not shown / not reported". Never 0, never `""`, never `"#-NA"` — the loaders convert portal `#-NA`/blank to null |
| Enums | Lowercase, from §4 only. A new value is a contract change (§10), never added quietly in code |
| Raw text | The platform's/portal's original words live in `*_raw` fields or bronze `raw` jsonb. Cleaned values live in silver; raw is never overwritten |
| Provenance | Every fact row carries its source pointer (`source_record_id`, `source_file`, `source_table`, `run_id`/`etl_run_id`) and `loaded_at` |

## 3. The records

### 3A. Scraped platform data (Scraping → bronze → silver)

| Record | Grain | Silver table | Fills dash |
|---|---|---|---|
| product_reading | product × store × run (price, stock, inventory, search position) | `silver.fact_product_reading` | `dash.pricing`, `dash.availability` |
| shelf_position | card on a category/search page × snapshot | `silver.fact_shelf_position` | `dash.visibility` |
| store_scan | one brand scan of one store (completeness/denominator record) | `silver.fact_store_scan` | denominators for coverage & SoV |

Key fields (full DDL is `sql/01_tables.sql`; only rules are repeated here):

**product_reading** — `observed_at` (UTC, not null), `stock_status` ∈ §4,
`is_listed` boolean not null, `is_available` boolean (null = unknown), `inventory_units`
int (capped → `inventory_is_capped = true`; cap is a minimum, never a maximum),
`selling_price`/`mrp` numeric(12,2); `discount_amount` and `discount_pct` are generated
columns — the scraper never sends derived values. `search_position`/`organic_position`
int, `is_ad`/`ad_type` as shown. `osa_eligible` not null. `dq_status` ∈ valid/suspect/invalid.

**shelf_position** — `shelf_position` int not null (1 = first tile), only meaningful
inside its own `snapshot_id`; a product missing from a scan is "not seen in N cards",
never `not_listed`. `is_client_brand` decides whether the card counts toward client SoV.
`shelf_cards_seen`/`shelf_total_items`/`shelf_complete` come from the scan record.

**store_scan** — one row per store per run per brand query: `scan_status`,
`pages_read`, `cards_seen`, `brand_cards_matched`, `is_complete`,
`is_valid_denominator` (excludes blocked/partial scans from availability and SoV
denominators). A blocked or incomplete scan must never look like "no stock".

### 3B. First-party portal data (Excel → `public.fp_blinkit_ads` → `silver.fact_fp_ads`)

Four record kinds: `keyword_daily`, `reco_daily`, `sov_period`, `mtd_claimables`.
Full field tables: see `fp_ads_data_contract_v1.md` §3. Summary:

| Kind | Grain | Notes |
|---|---|---|
| keyword_daily | date × campaign × keyword | spend, impressions, sales, ATC, qty, RoAS, position |
| reco_daily | date × campaign × asset | no keyword — structural, not missing |
| sov_period | keyword × date-range | searches + SoV % |
| mtd_claimables | campaign (month-to-date) | no date of its own |

A file is loaded at most once (sha256 in `public.fp_load_file`); overlapping exports
cannot double-count (unique index, `on conflict do nothing`). Zepto exports will join as
new parsers with `platform='zepto'` — never mixed in unlabelled.

### 3C. Reserved feeds (tables exist, producers not wired yet)

| Feed | Fills | Producer | Status |
|---|---|---|---|
| Daily sales per SKU | `dash.overview` (gmv, net_sales, units_sold, avg_selling_price, category_sales, market_share_pct, contribution_margin*) | seller-portal sales report | awaiting first export |
| Inventory / PO | `dash.supply` (po_number, po_status, grn_units, fill_rate_pct, expiry_date, invoice & payment blocks, EDI fields) | seller-portal inventory/PO/invoice exports | awaiting first export |
| SKU-level ads | `dash.ads.sidnl_id` | portal product-level ads report | awaiting first export |

*`contribution_margin` needs cost data (ERP, not portals) — likely stays null in v1.

## 4. Allowed values

| Field | Values |
|---|---|
| platform | `blinkit`, `zepto`, `instamart`, `jiomart` |
| stock_status (scraped) | the platform's raw states as captured in `stock_state_raw`; cleaned states used by dash: in_stock, out_of_stock, low_stock, not_listed, not_serviceable |
| dq_status | `valid`, `suspect`, `invalid` |
| report_type (fp) | `keyword_daily`, `reco_daily`, `sov_period`, `mtd_claimables` |
| report_level (dash.ads) | `keyword`, `sku`, `campaign` (generated: keyword → sku → campaign) |
| source_type / source_table | the pipeline's own registered values (`silver.pipeline_source`) — new feeds are registered, not improvised |
| po_status | as shown by portal, lowercased (reserved feed) |
| refresh status | `success`, `failed` (CHECK constraint on `dash.refresh_table_state.last_status`) |

## 5. Keys and the duplicate rule

| Record | Unique key | Rule |
|---|---|---|
| fp bronze row | (report_type, obs_date, campaign_id, subcampaign_id, target_value, period_start) | file sha256 registered; first load wins; duplicates skipped, never deleted |
| silver fp row | `fp_ads_id` = bronze id | 1:1 with bronze |
| product_reading | `reading_key` identity + (product_key, store_key, observed_at) semantics | retries/replays insert new rows; dash uses latest valid per day |
| shelf_position | (snapshot_id, shelf_position) | position only valid within its snapshot |
| store_scan | (snapshot_id, store_key/brand query) | one scan per store per run |
| dash.ads | (obs_date, platform, campaign_id, keyword, sidnl_id) | enforced by unique index `ads_key` |

Duplicate rule (same everywhere): the same fact arriving twice is stored once and
logged; two different values for the same key in one run → keep the latest valid
`observed_at`, flag the conflict. A late/replayed record never moves "latest state"
backwards.

## 6. Validation

Every fact row gets `dq_status` + `dq_flags`. Rows are kept and flagged — never deleted
or silently fixed.

| Code | Condition | Result |
|---|---|---|
| negative money / roas | spend, sales or roas < 0 (fp) | suspect |
| price_jump | selling_price differs > threshold from the same product/store's last valid price | suspect (scraped) |
| sp_gt_mrp | selling_price > mrp | suspect |
| units_capped | inventory at the platform cap | `inventory_is_capped = true` (info, still valid) |
| capped_without_units | capped but no units | suspect |
| not_a_denominator | scan incomplete/blocked | `is_valid_denominator = false` — excluded from availability & SoV |
| unparseable | portal value can't be converted to its type | row rejected at load (can't be keyed), file owner notified |
| missing date on daily row | fp keyword/reco row without obs_date | rejected at load |

Only `valid` rows reach dash. `suspect` rows stay in silver and are excluded from dash
until reviewed. Rows the silver→dash insert can't accept (schema mismatch, unknown
product) go to `ops.dead_letter` with reason and retry state — they are retried, not
discarded.

## 7. Where the data lives

| Layer | Objects | Mutated by | Mutations |
|---|---|---|---|
| Bronze | `public.fp_blinkit_ads`, `public.fp_load_file`, scraper bronze tables | loaders | insert-only |
| Silver | `silver.fact_product_reading`, `fact_shelf_position`, `fact_store_scan`, `fact_fp_ads`, `silver.dim_*`, `product_xref`, `match_review_queue`, `pipeline_source` | ETL jobs | insert-only; reference tables may be updated via reviewed PR |
| Dash (metrics) | `dash.ads`, `availability`, `pricing`, `visibility`, `overview`, `supply` | refresh functions (`dash.refresh_ads()`, `dash.refresh(...)`) | atomic delete+insert rebuild |
| Dash (dims/config) | `dash.dim_brand`, `dim_category`, `dim_city`, `dim_date`, `dim_platform`, `dim_product`, `dim_sidnl`, `dim_store`, `cfg_sku`, `cfg_threshold` | config owner | updates logged; changes via PR |
| Dash (state) | `refresh_table_state`, `refresh_state`, `metric_catalog` | refresh functions | upsert |
| Ops | `ops.dead_letter`, `ops.alert_outbox`, `ops.cron_alert_log`, `ops.backup_*` | pipeline | insert + status updates |

**SKU mapping:** scraped platform products map to our canonical `sidnl_id` via
`silver.product_xref` + `dash.dim_product.sidnl_id`. Ambiguous matches go to
`silver.match_review_queue` (status pending → decided_by/decided_at) — nothing is
auto-merged without a rule or a human decision. Different pack sizes are different
SKUs and are never merged.

**Frontend-facing objects (the API's whole world):**
`dash.ads`, `dash.availability`, `dash.pricing`, `dash.visibility`, `dash.overview`,
`dash.supply`, `dash.v_sov_keyword`, `dash.v_brand_scorecard`,
`dash.v_refresh_status`, `dash.v_platform_freshness`, plus dims for filters.

## 8. Metric derivations (dash-level only; inputs are never mutated)

- All dash tables are rebuilt from silver by refresh functions; the metric formulas are
  catalogued in `dash.metric_catalog` (metric_key, formula, status, gold_table,
  missing_inputs, owner_team) — that table is the machine-readable half of this contract.
- Percent metrics (availability %, OSA %, SoV %, fill_rate_pct) always expose numerator
  and denominator columns alongside — no opaque percentages.
- RoAS in dash is recomputed from summed sales ÷ summed spend, never averaged from
  per-row ratios.
- Counts use each store's last valid observation of the IST day; not_serviceable /
  not_listed / invalid / non-denominator scans are reported separately and never enter
  the denominator.

## 9. Known gaps / open items

| Item | Feed | Status |
|---|---|---|
| Clicks / CTR / CPC / Reach | fp ads | portal doesn't export them in current tabs; buttons exist, show "no data" |
| SKU-level ads report | fp ads | unlocks `dash.ads.sidnl_id` and SKU RoAS |
| Zepto (and Instamart/Jiomart) everything | all | scrapers/exports pending; `silver.zepto`/`instamart`/`jiomart` tables reserved |
| Daily sales report | reserved | unlocks `dash.overview` (currently empty) |
| Inventory/PO/invoice/EDI | reserved | unlocks `dash.supply` (currently empty) |
| City-split ads data | fp ads | ads reports are national today |
| MTD row collision (campaign 284970, Oct-19) | fp ads | cosmetic; optional fix |
| Market share / contribution margin | `dash.overview` | needs category sales + ERP cost data |

## 10. Changing this contract, and sign-off

Lives in the repo (`data-sidnl/contracts/`); changes only via reviewed PR. A new optional
field or record = minor (1.0 → 1.1). A renamed/removed field, changed type, new enum
value, or changed key = major (needs DataEng + Scraping + Backend sign-off; both versions
accepted for one week). Loaders never guess: a file or record whose shape doesn't match a
known parser fails loudly instead of loading silently-wrong data.

| Team | What they confirm |
|---|---|
| Scraping | scraper records match §3A; failure scans never look like stock-outs |
| DataEng | parsers, silver tables and dash refreshes follow §3–§8; nothing deleted without sign-off |
| Backend | API reads dash only (§7 list); respects report_level/dq rules of §4–§6 |
