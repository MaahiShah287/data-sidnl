# SIDNL Frontend Button → SQL Query Map (first-party ads)

Nov 11, 2026 · For the Backend/FastAPI team.

Every query below is **read-only** and hits only the two frontend-facing objects:

| Object | Grain | Rows today |
|---|---|---|
| `dash.ads` | one row per date × platform × campaign × keyword (keyword rows) or per date × campaign (campaign rows) | 95 |
| `dash.v_sov_keyword` | one row per keyword per period | 2 |

All other `fp_*` / silver objects are internal pipeline plumbing — never query them from the API.

**Golden rule for every query:** always include `report_level` in `where`/`group by`.
`report_level = 'keyword'` = daily keyword rows; `'campaign'` = daily reco summaries and the
MTD campaign summary. Mixing them double-counts spend and impressions.

Placeholders: `:date_from`, `:date_to` (dates), `:platform` (`'blinkit'`), `:campaign_id`,
`:keyword`. All are optional filters unless noted.

---

## 1. Ads Overview page — headline KPI cards

**Button/page:** Ads → Overview (spend, attributed sales, RoAS, impressions for a date range)

```sql
select
    sum(ad_spend)                                        as total_spend,
    sum(attributed_sales)                                as attributed_sales,
    case when sum(ad_spend) > 0
         then sum(attributed_sales) / sum(ad_spend) end  as blended_roas,
    sum(impressions)                                     as impressions,
    sum(new_users_acquired)                              as new_users
from dash.ads
where platform = :platform
  and obs_date between :date_from and :date_to
  and report_level = 'keyword';        -- daily keyword rows only, no MTD summary
```

## 2. Ads trend chart — daily series

**Button/page:** Ads → trend line (spend & RoAS per day)

```sql
select obs_date,
       sum(ad_spend)         as spend,
       sum(attributed_sales) as attributed_sales,
       case when sum(ad_spend) > 0
            then sum(attributed_sales) / sum(ad_spend) end as roas
from dash.ads
where platform = :platform
  and obs_date between :date_from and :date_to
  and report_level = 'keyword'
group by obs_date
order by obs_date;
```

## 3. Keyword table — per-keyword performance

**Button/page:** Ads → Keywords tab (sortable table: keyword, spend, RoAS, sales, position)

```sql
select obs_date, campaign_id, campaign_name, keyword, match_type,
       ad_spend, impressions, most_viewed_position,
       direct_sales, indirect_sales, attributed_sales,
       direct_roas, total_roas,
       direct_atc, indirect_atc, atc,
       new_users_acquired, direct_qty_sold, indirect_qty_sold, total_qty_sold
from dash.ads
where platform = :platform
  and obs_date between :date_from and :date_to
  and report_level = 'keyword'
  and (:keyword is null or keyword = :keyword)
order by obs_date desc, total_roas desc nulls last;
```

## 4. Keyword leaderboard — aggregated over the range

**Button/page:** Ads → "Top keywords" card

```sql
select keyword,
       sum(ad_spend)        as spend,
       sum(attributed_sales) as attributed_sales,
       sum(impressions)     as impressions,
       case when sum(ad_spend) > 0
            then sum(attributed_sales) / sum(ad_spend) end as roas,
       max(most_viewed_position) as best_position,
       count(distinct obs_date)  as days_active
from dash.ads
where platform = :platform
  and obs_date between :date_from and :date_to
  and report_level = 'keyword'
group by keyword
order by roas desc nulls last;
```

## 5. Campaign drill-down

**Button/page:** click a campaign card / filter by campaign

```sql
-- daily series for one campaign (keyword rows)
select obs_date, keyword, ad_spend, impressions, attributed_sales,
       direct_roas, total_roas, most_viewed_position
from dash.ads
where platform = :platform
  and campaign_id = :campaign_id
  and obs_date between :date_from and :date_to
  and report_level = 'keyword'
order by obs_date desc;

-- campaign-level daily rollup (reco ads live only at this level)
select obs_date, campaign_name, ad_spend, impressions, attributed_sales, total_roas
from dash.ads
where platform = :platform
  and campaign_id = :campaign_id
  and report_level = 'campaign'
  and keyword is null            -- excludes the MTD summary row
  and obs_date between :date_from and :date_to
order by obs_date desc;
```

## 6. MTD campaign summary (budget & claimables context)

**Button/page:** campaign card footer — "month-to-date" chip

```sql
-- MTD rows: report_level = 'campaign' with campaign_budget + impressions set,
-- landing on the latest known ads date. Identify by no spend attribution:
select campaign_id, campaign_name, campaign_type, campaign_budget, impressions, obs_date
from dash.ads
where platform = :platform
  and report_level = 'campaign'
  and ad_spend is null            -- MTD summary row marker
order by campaign_id;
```

## 7. Share of Voice card

**Button/page:** Ads → SoV widget

```sql
select keyword, searches, sov_pct, period_start, period_end
from dash.v_sov_keyword
where (:keyword is null or keyword = :keyword)
order by period_end desc, sov_pct desc;
```

Expected today: `chaap` → 10.23% of 82,474 searches; `soya chaa` → 71.1% of 3,525
(period 2026-10-01 → 2026-11-01).

## 8. Date-picker / freshness check

**Button/page:** any page load — what date range has data?

```sql
select min(obs_date) as data_from, max(obs_date) as data_to,
       count(*) as rows_loaded
from dash.ads
where platform = :platform;
```

## 9. Export / CSV download

**Button/page:** Ads → Export. Same query as §3 (keyword detail), no limit — Backend
streams it as CSV. Do **not** include `report_level = 'campaign'` rows in the same export
unless the UI has a separate "campaign summary" export, which uses §5's second query.

---

## Query-contract rules for Backend (summary)

1. Read **only** `dash.ads` and `dash.v_sov_keyword`.
2. Always filter `platform = 'blinkit'` (until Zepto lands) — the column exists and will
   gain a second value later.
3. Always handle `report_level`; daily metrics = `'keyword'` only.
4. `obs_date` is the portal's IST reporting date; range-filter with `between` (inclusive).
5. `null` means "not reported", never 0 — don't coalesce money to 0 in aggregates; use
   `sum()` which ignores nulls.
6. RoAS shown to users should be computed from summed sales ÷ summed spend (§1/§2/§4), not
   averaged from per-row `direct_roas`.
7. The tables refresh via `dash.refresh_ads()` (cron every 15 min, or after each Excel
   load). There is no write path from the API — the app is read-only on these objects.
