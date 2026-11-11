# SIDNL Frontend Button → SQL Query Map (first-party ads)

Nov 11, 2026 · For the Backend/FastAPI team. Updated for `silver_074` / `dash_012` (dash built from the formula sheet).

Every query below is **read-only** and hits only these frontend-facing objects:

| Object | Grain | Rows today |
|---|---|---|
| `dash.ads` | one row per date × platform × campaign × (keyword \| placement), plus one rollup row per date × campaign | 183 |
| `dash.ads_campaign_period` | one row per campaign × MTD report period (budget, claimables) | 2 |
| `dash.ads_keyword_sov` | one row per keyword × sponsored-SoV report period | 2 |
| `dash.v_sov_keyword` | same as `ads_keyword_sov` (old column names, kept for existing callers) | 2 |

All `fp_*` / silver objects are internal pipeline plumbing — never query them from the API.

**Golden rule: filter one `report_level` per query.**

| `report_level` | What it is | Rows today |
|---|---|---|
| `'campaign'` | one campaign on one day = all its keyword or placement rows added up, + daily budget and budget utilisation. **Use for every total, KPI card and trend.** | 38 |
| `'keyword'` | keyword ads (Product Booster): one keyword of a campaign on one day | 75 |
| `'placement'` | recommendation ads: one placement (Next Product / Similar Product / Repeat Order …) on one day | 70 |

`'keyword'` + `'placement'` together = `'campaign'`. Adding `'campaign'` to either double-counts.

Placeholders: `:date_from`, `:date_to` (dates), `:platform` (`'blinkit'`), `:campaign_id`, `:keyword`.

---

## 1. Ads Overview page — headline KPI cards

```sql
select sum(ad_spend)                                                  as total_spend,
       sum(attributed_sales)                                          as attributed_sales,
       round(sum(attributed_sales) / nullif(sum(ad_spend), 0), 2)     as total_roas,
       round(sum(direct_sales) / nullif(sum(ad_spend), 0), 2)         as direct_roas,
       sum(impressions)                                               as impressions,
       round(sum(ad_spend) * 1000 / nullif(sum(impressions), 0), 2)   as effective_cpm,
       sum(atc)                                                       as add_to_carts,
       sum(total_qty_sold)                                            as units_sold,
       sum(new_users_acquired)                                        as new_users
from dash.ads
where platform = :platform
  and obs_date between :date_from and :date_to
  and report_level = 'campaign';
```
Expected for 2026-10-01 → 2026-10-19: spend 23,255.30 · attributed sales 53,460.00 · total RoAS 2.30 ·
impressions 96,851 (= the MTD Claimables sheet: 7,193.10 + 16,062.20 spend, 16,540 + 80,311 impressions).

## 2. Ads trend chart — daily series

```sql
select obs_date,
       sum(ad_spend)                                              as spend,
       sum(attributed_sales)                                      as attributed_sales,
       round(sum(attributed_sales) / nullif(sum(ad_spend), 0), 2) as roas
from dash.ads
where platform = :platform and obs_date between :date_from and :date_to
  and report_level = 'campaign'
group by obs_date
order by obs_date;
```

## 3. Keyword table — per-keyword, per-day

```sql
select obs_date, campaign_id, campaign_name, keyword, match_type, cpm_bid, cpm,
       ad_spend, impressions, most_viewed_position, kw_volume_monthly,
       direct_sales, indirect_sales, attributed_sales, direct_roas, total_roas,
       direct_atc, indirect_atc, atc, new_users_acquired,
       direct_qty_sold, indirect_qty_sold, total_qty_sold
from dash.ads
where platform = :platform and obs_date between :date_from and :date_to
  and report_level = 'keyword'
  and (:keyword is null or keyword = :keyword)
order by obs_date desc, total_roas desc nulls last;
```
`cpm` = effective CPM (spend ÷ impressions × 1000); `cpm_bid` = the CPM set on the keyword.
`kw_volume_monthly` = searches in the SoV report period: an attribute, **never sum it across days**.

## 4. Keyword leaderboard — over the range

```sql
select keyword,
       sum(ad_spend)                                              as spend,
       sum(attributed_sales)                                      as attributed_sales,
       sum(impressions)                                           as impressions,
       round(sum(attributed_sales) / nullif(sum(ad_spend), 0), 2) as roas,
       min(most_viewed_position)                                  as best_position,
       max(kw_volume_monthly)                                     as searches_in_period,
       count(distinct obs_date)                                   as days_active
from dash.ads
where platform = :platform and obs_date between :date_from and :date_to
  and report_level = 'keyword'
group by keyword
order by roas desc nulls last;
```

## 5. Recommendation placements

```sql
select placement,
       sum(ad_spend)                                              as spend,
       sum(impressions)                                           as impressions,
       sum(attributed_sales)                                      as attributed_sales,
       round(sum(attributed_sales) / nullif(sum(ad_spend), 0), 2) as roas,
       sum(new_users_acquired)                                    as new_users
from dash.ads
where platform = :platform and obs_date between :date_from and :date_to
  and report_level = 'placement'
group by placement
order by spend desc;
```

## 6. Campaign drill-down

```sql
-- one campaign per day, with daily budget and utilisation
select obs_date, campaign_name, campaign_type, campaign_budget, budget_utilisation_pct,
       ad_spend, impressions, attributed_sales, direct_roas, total_roas
from dash.ads
where platform = :platform and campaign_id = :campaign_id
  and obs_date between :date_from and :date_to
  and report_level = 'campaign'
order by obs_date desc;
```
For the detail under it, use §3 (keyword campaigns) or §5 (recommendation campaigns) with `campaign_id = :campaign_id`.

## 7. MTD campaign summary (budget & claimables)

```sql
select campaign_id, campaign_name, campaign_type, period_start, period_end,
       total_budget, claimables, served_budget_consumed, budget_utilisation_pct, impressions,
       daily_ad_spend, daily_days, spend_reconciled
from dash.ads_campaign_period
where platform = :platform
order by period_end desc, campaign_id;
```
Expected today (period 2026-10-01 → 2026-10-31): 284970 Chaap Aug 2025 — budget 95,000, claimables 7,193.10,
7.57 % used; 330981 Recommendation — budget 47,500, claimables 16,062.20, 33.82 % used. `spend_reconciled = true`
means the daily rows add up to the platform's month figure.

## 8. Share of Voice card

```sql
select keyword, period_start, period_end, searches, sponsored_sov_pct,
       ad_impressions, ad_spend, attributed_sales, total_roas, ad_days
from dash.ads_keyword_sov
where platform = :platform and (:keyword is null or keyword = :keyword)
order by period_end desc, sponsored_sov_pct desc;
```
Expected today: `chaap` 10.23 % of 82,474 searches; `soya chaa` 71.10 % of 3,525 (2026-10-01 → 2026-11-01).

## 9. Date-picker / freshness

```sql
select min(obs_date) as data_from, max(obs_date) as data_to
from dash.ads where platform = :platform and report_level = 'campaign';

select table_name, last_refreshed_at, last_status, refresh_failing
from dash.v_refresh_status where table_name like 'ads%';
```

## 10. Export / CSV

Keyword detail = §3, placement detail = §5 without `group by`, campaign summary = §6. One `report_level` per file.

---

## Query-contract rules for Backend (summary)

1. Read only `dash.ads`, `dash.ads_campaign_period`, `dash.ads_keyword_sov` (and `dash.v_refresh_status`).
2. Always filter `platform` — it will gain values when other platforms' feeds land.
3. One `report_level` per query; totals and trends use `'campaign'`.
4. `obs_date` is the portal's IST reporting date; range-filter with `between` (inclusive).
5. `null` = "not in the source data", never 0. Columns that are always NULL today because the Blinkit exports do not
   have them: `clicks`, `reach`, `ctr_pct`, `cpc`, `aov`, `conversion_rate_pct`, `keyword_rank`,
   `keyword_opportunity`, `campaign_status`, `is_campaign_on`, `sidnl_id`. Hide those widgets rather than show 0.
6. Ratios (RoAS, CPM, utilisation) shown for a range = summed numerator ÷ summed denominator, never an average of
   per-row ratios.
7. Every column is one metric in the formula sheet `silver.ref_metric_support` (`dash_table`, `dash_column`,
   `sql_expr`); ask data engineering there for a definition. The tables refresh on every Excel upload (trigger)
   and every 10 min (cron `sidnl-fp-ads`). The API never writes to them.
