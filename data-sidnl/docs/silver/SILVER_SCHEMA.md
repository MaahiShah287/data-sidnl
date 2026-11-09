# Silver layer

Bronze (`public.*`, untouched) -> **silver** -> gold. Silver holds only what the metrics in the metrics guide need;
scraper bookkeeping is not copied. Pipeline run history and data-quality results live in schema `ops`.

## Metric tables
| Table | Grain | Feeds |
|---|---|---|
| `dim_platform`, `dim_city`, `dim_store`, `dim_brand`, `dim_category` | conformed dimensions | all |
| `dim_product` | platform x platform_product_id (pack parsed to size/unit/count) | all |
| `canonical_product` | one row per real-world product | SI lookups |
| `product_xref` | `dim_product` -> canonical product, with match method and score | SI lookups |
| `fact_product_reading` | one product at one store at one time (price, MRP, stock, inventory, position) | OSA, price, discount, inventory, rank |
| `fact_shelf_position` | one product card on a category shelf (all brands) | SOV, visibility, competitor price |
| `fact_store_scan` | one brand-search scan of a store | listing % denominator |

The live Silver schema has 20 tables and 16 views. Pipeline bookkeeping is in
`ops`, not Silver. SI ids are assigned and re-sequenced alphabetically by
product name; consumers use the SI-keyed views. SI ids are not persisted on
Silver fact rows.

## Configuration that drives the automation
`brand_scope`, `category_scope`, `pipeline_source` (bronze watermarks), `sidnl_config`, `ref_noise_word`, `ref_variant_synonym`,
`freshness_policy`, `brand_string_registry`, `match_review_queue`, `ref_metric_support`.

## Views
`v_sidnl_product` (one row per SI id), `v_reading_by_sidnl`,
`v_shelf_by_sidnl` (includes `product_key`), `v_canonical_product_map`,
`v_canonical_brand_summary`, `v_reading`, `v_reading_current`, `v_wide`,
`blinkit`, `zepto`, `instamart`, `jiomart`, `v_sku_listing`,
`v_shelf_position`, `v_data_freshness`, and `v_match_health`.

The redundant `v_category_shelf` and `v_dim_product_sidnl` views, plus the
empty `demo` compatibility view, are no longer in the live schema.

## Not in scraped data
Sales, market share, DRR/DOI, back-end inventory, PO / GRN / invoice / debit-note / payment, ad spend and keyword volume need
vendor-portal files, so there are no tables for them until that data exists.

## Data quality
Each row has `dq_status` (valid / suspect / invalid). Metrics filter `dq_status = 'valid'`. Results per run: `ops.dq_result`.
