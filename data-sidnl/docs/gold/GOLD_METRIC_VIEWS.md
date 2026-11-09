# Gold metric views

Gold is built in-database from Silver. The API reads Gold only. Metric-named
objects added by migrations 060–063 are **views**, not additional stored
tables; they do not add another metric refresh or duplicate metric data.

## Metric views

| Area | Views |
|---|---|
| Pricing | `mrp_daily`, `sp_daily`, `discount_daily` |
| Share of voice | `overall_sov_daily`, `organic_sov_daily`, `paid_sov_daily`, `top_of_search_sov_daily`, `category_impression_share_daily`, `competitor_price_discount_daily` |
| Availability | `avg_osa` |
| Priority and loss (OSA-based proxies) | `critical_skus_current`, `priority_proxy_current`, `psl_proxy_current` |

Fifteen `gold.metric_catalog` entries point to these views. Existing objects
that already represent a metric remain unchanged: `osa_daily`, `osa_dn`,
`assortment_daily`, `listing_snapshot`, `inventory_current`,
`inventory_summary`, `sku_rank_daily`, and `price_parity_*`.

The blocked metrics (sales, DRR, DOI, warehouse stock, PO/GRN/invoice/payment
metrics, ad spend, keyword volume, and expiry) have no new metric object
because their required data is not present. Existing empty placeholder tables
are unchanged. No demo or sample rows are introduced.

## Refresh behavior

- `gold.sync_dims()` is run once per `gold.refresh_all()` transaction, using
  transaction-local setting `gold.dims_synced`. The reported runtime fell from
  about 3.1 seconds to 0.03 seconds, with unchanged dimension row counts.
- Visibility refresh tracks changed shelf dates in `gold.refresh_state`. It
  refreshes only changed dates unless the top-N setting, enabled client brands,
  or category names change; those changes trigger a full visibility rebuild.
- The initial full visibility rebuild seeds that state. Reported times are
  about 9 seconds for one changed date and 1.3 seconds when nothing changed,
  compared with about 35 seconds for a full shelf rescan.
- Gold refreshes use `DELETE`, not `TRUNCATE`, so readers are not blocked by a
  truncate lock.
- A partial Silver run does not trigger Gold refresh; the last clean Gold
  result remains available.

The first Gold run after new Silver data lands will seed visibility change
tracking with a full rebuild. The reported full refresh took about 38 seconds;
subsequent incremental refreshes were estimated at about 14 seconds.

## Migration source

Migrations 060–063 are reported as applied in Supabase. Exact statements,
Supabase migration versions, and hashes are not included in this repository
snapshot; do not reconstruct or apply guessed SQL. Export the exact migration
statements and metadata before adding them to the migration manifest or using
them to build a clean-install baseline.
