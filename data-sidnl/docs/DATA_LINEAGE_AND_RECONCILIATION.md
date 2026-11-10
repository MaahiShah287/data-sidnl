# Where every dashboard number comes from (and how it is checked)

Bronze = every schema except `silver` and `dash` (today: the `public` scraper tables). Nothing in silver or dash is
typed in or estimated: each row is derived from bronze rows by SQL, and a daily job proves it.

## Why dash has ~100k rows when silver has ~7k products
Silver has **7,137 canonical products (SI ids)** and **7,149 platform listings**. Those are the *products*. The facts are
much larger: **1,832,098 shelf rows** and **56,249 store readings**, each one row in bronze. Dash stores each product
**once per day × city (and × store) where it was actually seen**, so it has more rows than products, and far fewer than the facts:

| Dash table | Rows (2026-11-10) | One row per | Built from |
|---|---|---|---|
| `dim_sidnl` / `dim_product` | 7,137 / 7,149 | product / platform listing | `silver.canonical_product`, `silver.dim_product` (same counts) |
| `availability`, store rows | 49,292 | day × dark store × SKU (945 stores, ~10.5 client SKUs per store-day) | store readings |
| `availability`, city rows | ~1,300 | day × platform × city × SKU | the same readings, summed |
| `pricing` | 1,186 | day × platform × city × SKU with a price | latest reading per store, averaged across stores |
| `visibility` | ~37,400 | day × platform × city × category shelf × SKU | latest shelf snapshot per store, impressions counted |
| `v_brand_scorecard` | view | day × platform × city × brand | sums of the three tables above |

## The chain, and the proof for each link
```
public.* (bronze rows)
  └─► silver.fact_shelf_position / fact_product_reading   (one silver row = one bronze row; values copied, never changed)
        └─► dash.pricing / availability / visibility       (aggregations: counts, sums, averages of those rows)
              └─► dash.v_brand_scorecard                    (sums of dash rows; every % has its numerator and denominator)
```
`silver.reconcile()` (cron `sidnl-reconcile`, daily 19:20 UTC) checks each link with SQL that is separate from the
pipeline, and writes the result to `ops.reconciliation_log`. The latest result per check is in `ops.v_reconciliation_latest`.
Result of the first run, 2026-11-10 11:00 UTC:

| Check | What is compared | Rows checked | Mismatches |
|---|---|---|---|
| `readings_vs_bronze` | every reading vs its bronze row: price, MRP, time, store, platform, product, city | 56,249 | 0 |
| `shelf_vs_bronze` | every shelf fact vs its bronze row: price, MRP, inventory, rank, organic rank, ad flag, product, snapshot, time, platform, city | 1,832,098 | 0 |
| `dash_pricing` | `dash.pricing` vs an independent re-aggregation of silver readings | 1,186 | 0 |
| `dash_osa` | availability OSA counts vs silver readings | 111 | 0 |
| `dash_visibility` | category impressions vs silver shelf facts | 37,028 | 0 |
| `scorecard_totals` | brand impressions add up to the market total | 78 | 0 |

Any mismatch writes an alert row to `ops.cron_alert_log` (`jobname = 'sidnl-reconcile:data'`).

## The one place silver adds information not on the bronze row itself: city (silver_060)
191 bronze stores have no city on `public.stores`, but the bronze scrape snapshots taken at those stores record the
city. For 189 of them every snapshot names the same single city, and silver uses that city (logged per store in
`ops.store_city_filled`). The 2 stores whose snapshots name two cities (Delhi/Gurugram border) keep no city and show
as "(unknown)" (374 visibility rows). Before this fix, 114,515 shelf rows and 162 readings showed as "(unknown)" city.
