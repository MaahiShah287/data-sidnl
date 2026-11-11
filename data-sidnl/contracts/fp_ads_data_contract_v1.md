# SIDNL First-Party Data Contract v1 (ads)

Nov 11, 2026 · @dev · For: DataEng (Upen), Backend (Atharva/FastAPI)

## 1. What this contract is

The rulebook for what the seller portals (Blinkit today; Zepto when exports arrive) hand to
Data Engineering: which records, which fields, which types, which values are allowed, and
what counts as bad data. Anything that breaks it is flagged (`dq_status`); nothing reaches
the app silently.

- **Producer:** a human downloads the portal Excel export into `first_party/` (repo root,
  git-ignored — company data is never committed). `scripts/load_first_party.py` parses it.
- **Consumer:** Data Engineering's pipeline: bronze `public.fp_blinkit_ads` → silver
  `silver.fact_fp_ads` → dash `dash.refresh_ads()` → `dash.ads` / `dash.v_sov_keyword`.
- **Reader:** Backend's API reads `dash.ads` and `dash.v_sov_keyword` only — never bronze
  or silver.

Not the loader: the loader is code that enforces this contract. This document is what it
enforces.

Core principle (agreed, non-negotiable): **append-only**. Bronze and silver never delete and
never update loaded rows. Every row keeps its `loaded_at`. Corrections are new rows; dash
tables are the only layer rebuilt (`delete` + insert inside one transaction), and they can
always be regenerated from bronze.

## 2. Rules that apply to every field

| Topic | Rule | Example |
|---|---|---|
| Names | snake_case, English, no abbreviations except `id`, `sku`, `cpm`, `roas`, `sov`, `atc` | `budget_consumed`, not `spent` |
| Platform IDs | Always text, even when they look like numbers | `campaign_id = "284970"` |
| Dates | `date` (IST business date as the portal reports it) | `2026-10-19` |
| Timestamps | `timestamptz` in UTC (`loaded_at`); IST only on screen | — |
| Money | Rupees, `numeric(14,2)`. Never paise, never float | `7193.10` |
| Rates | Percent as a number 0–100, `numeric(7,3)`; RoAS as a ratio | `sov_pct = 10.23`, `direct_roas = 1.64` |
| Counts | Whole numbers (`bigint`) | `impressions = 1272` |
| Empty | `null` means "not shown / not reported". Never 0, never `""`, never `"#-NA"` — the loader converts portal `#-NA`/blank to null | `match_type = null` |
| Platform | Lowercase enum: `blinkit`, `zepto` (later). Never inferred from data — set per file at load time | `platform = 'blinkit'` |
| Provenance | Every bronze row carries `source_file` + `loaded_at`; every file's sha256 is registered in `public.fp_load_file` | — |
| Raw text | The portal's original row is kept verbatim in `raw` (jsonb). Cleaned values live in silver; raw is never edited | — |

## 3. The records the pipeline emits

Four record kinds (one per portal report tab). One Excel file yields rows of one or more kinds.

| Record | Grain | Source tab (Blinkit) |
|---|---|---|
| `keyword_daily` | one row per date × campaign × keyword | `Keyword Targeting` / `PRODUCT_LISTING` |
| `reco_daily` | one row per date × campaign × subcampaign/asset | `Product Recommendation` / `PRODUCT_RECOMMENDATION` |
| `sov_period` | one row per keyword for a date range | `Sponsored SoV` |
| `mtd_claimables` | one row per campaign (month-to-date summary) | `MTD Claimables` |

Zepto exports will map onto the same four kinds (or new kinds added here first) — never
mixed in without `platform = 'zepto'`.

### 3.1 keyword_daily

| Field | Type | Req | Meaning / rule |
|---|---|---|---|
| `obs_date` | date | yes | The portal's reporting date (IST). Parses `YYYY-MM-DD` and `DD-MM-YYYY` |
| `campaign_id` | text | yes | Platform's campaign id, as text |
| `campaign_name` | text | yes | As shown, e.g. `Chaap Aug 2025` |
| `target_value` | text | yes | The keyword (e.g. `chaap`, `tandoori soya chaap`) |
| `match_type` | text | no | `EXACT`, `PHRASE`, `BROAD` — as shown, uppercased by portal |
| `pacing_type` | text | no | `DAILY`, etc. |
| `most_viewed_position` | int | no | Best rank achieved that day |
| `cpm` | numeric(14,2) | no | Cost per 1000 impressions |
| `total_budget` | numeric(14,2) | no | Campaign budget |
| `impressions` | bigint | yes | |
| `direct_atc` / `indirect_atc` | bigint | no | Add-to-carts |
| `new_users` | bigint | no | |
| `direct_sales` / `indirect_sales` | numeric(14,2) | no | Attributed sales, rupees |
| `direct_qty` / `indirect_qty` | bigint | no | Units sold |
| `budget_consumed` | numeric(14,2) | yes | Spend. This is the RoAS denominator |
| `direct_roas` / `total_roas` | numeric(10,2) | no | As reported by portal (never recomputed in bronze/silver) |

### 3.2 reco_daily

Same metrics as keyword_daily, plus `subcampaign_id` and `target_value` = asset/title,
**no keyword and no match_type**. Recommendation ads have no keyword — that is structural,
not missing data.

### 3.3 sov_period

| Field | Type | Req | Meaning / rule |
|---|---|---|---|
| `period_start` / `period_end` | date | yes | Inclusive range the portal aggregated |
| `target_value` | text | yes | Keyword |
| `searches` | bigint | yes | Total searches of that keyword in the period |
| `sov_pct` | numeric(7,3) | yes | Our share of voice, 0–100 |

### 3.4 mtd_claimables

| Field | Type | Req | Meaning / rule |
|---|---|---|---|
| (no date) | — | — | Summary grain; `obs_date` is assigned only at dash level (latest known ads date), never in bronze/silver |
| `campaign_id` / `campaign_name` | text | yes | |
| `ad_type` | text | yes | `Product Booster`, `Recommendation Ads` |
| `impressions`, `total_budget`, `claimables`, `served_budget` | numeric/bigint | yes | Month-to-date figures |

## 4. Keys and the duplicate rule

Bronze unique key: `(report_type, obs_date, campaign_id, subcampaign_id, target_value, period_start)`
(nulls coalesced to `''` / `1900-01-01`).

1. **A file is loaded at most once.** Its sha256 is registered in `public.fp_load_file`;
   re-running the loader on the same file is a no-op.
2. **Overlapping exports cannot double-count.** Two files reporting the same
   (report_type, date, campaign, keyword) — e.g. the `791_` and `Report_` exports — insert
   once, `on conflict do nothing`. Whichever loads first wins; the other's rows are skipped
   (never deleted).
3. **Silver is 1:1 with bronze** (`fp_ads_id` FK). No dedup, no merge, values unchanged.
4. **Nothing is deleted.** A wrong value stays in bronze with its `loaded_at`; if a
   correction is ever needed it will be a new row + a `dq_status` decision, shown to the
   team first.

## 5. Validation

Every silver row carries `dq_status` ∈ `valid` | `suspect` | `invalid` (default `valid`).

| Code | Condition | Result |
|---|---|---|
| negative money / RoAS | `direct_sales < 0`, `budget_consumed < 0`, roas < 0 | `suspect` |
| future date | `obs_date > today` | (planned) `suspect` |
| missing date on a daily row | keyword_daily/reco_daily with null date | rejected at load (row can't be keyed) |

Only `valid` rows reach dash. `suspect` rows stay in silver (never deleted) and are excluded
from dash until reviewed.

## 6. Where the data lives

| Layer | Object | Mutated by |
|---|---|---|
| Bronze | `public.fp_blinkit_ads` | loader inserts only |
| Bronze | `public.fp_load_file` | loader inserts only |
| Silver | `silver.fact_fp_ads` | `silver.load_fp_ads()` inserts only |
| Dash | `dash.ads` | `dash.refresh_ads()` atomic rebuild (delete+insert) |
| Dash view | `dash.v_sov_keyword` | view over silver; always current |

### Dash-level derivations (the only places values are computed)

- Reco daily rows are **collapsed to campaign-level per day** (sum impressions, spend,
  sales; RoAS recomputed as sales ÷ spend) because `dash.ads` PK is
  `(obs_date, platform, campaign_id, keyword, sidnl_id)` and reco has no keyword.
- MTD summary rows land on `obs_date` = latest known ads date. Known quirk: campaign
  284970's MTD row collides with its Oct-19 reco row and is dropped (`on conflict do
  nothing`); fix pending if wanted.
- `report_level` = `keyword` | `sku` | `campaign` (generated column) — the Backend must
  filter on it so daily keyword rows and campaign summaries aren't mixed in aggregates.

## 7. Known gaps (open items before v1.1)

| Item | Status |
|---|---|
| Clicks / CTR / CPC | Portal doesn't expose clicks in these exports — check other tabs |
| SKU-level ads report | Most valuable missing export; would fill `dash.ads.sidnl_id` |
| Zepto ads/sales/inventory exports | Reserved; same tables, new parsers, `platform='zepto'` |
| Daily sales report | Unlocks `dash.overview` |
| Inventory / PO report | Unlocks `dash.supply` |
| MTD row collision (284970) | Cosmetic; optional fix |

## 8. Changing this contract

Lives in the repo (`data-sidnl/contracts/`); changes only via reviewed PR. New optional
field = minor (1.0 → 1.1). New report_type, renamed/removed field, changed type or key =
major (needs DataEng + Backend sign-off). The loader never guesses: a file whose sheet
shape doesn't match a known parser fails loudly (`no parser for <file>`) instead of
silently loading wrong data.
