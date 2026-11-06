# Silver layer (brand-scoped star schema)

Bronze (`public.*` scraper tables) -> **silver** (this) -> gold (`sql/gold/*`, reads `silver.<platform>` views).
ERD: `docs/silver/erd.svg` (source `erd.mmd`). Metric coverage: `select * from silver.ref_metric_support`.

## Grain
| Table | Grain |
|---|---|
| `fact_product_reading` | one product x store observation from one source record (`unique(source_type, source_record_id)`) |
| `fact_store_scan` | one brand-search scan of one store (denominator for listing %) |
| `dim_product` | platform x platform_product_id (pack parsed into size/unit/count) |
| `dim_store`, `dim_city`, `dim_category`, `dim_brand`, `dim_platform` | conformed dimensions |

## Source types
`stock_check` (product page; the only source for OSA, `osa_eligible`), `brand_search` (search cards; listing %, position, ads), `category_shelf` (shelf rows; SOV once competitors are loaded).

## Brand scope
`silver.brand_scope` holds the brands to load; matching is on a normalised exact key of distinct raw brand strings, never `ILIKE '%munch%'`.

## Fresh vs stale
Nothing is deleted. `v_reading.freshness` is computed at query time from `silver.freshness_policy` (stock_check 48h, brand_search 24h, category_shelf 72h).

## Data quality
Each reading has `dq_status` (valid / suspect / invalid) and `dq_flags`. Metrics must filter `dq_status = 'valid'`.

## Parser (all in Postgres, tested by `silver.selftest_parser()`)
`parse_pack` ('270 g', '1 L', '6 x 330 ml', '1 pc (38.5 g)'), `parse_variant`, `map_stock_status`, `reading_dq`, `dq_status`, `norm_key`, `brand_matches`.

## Views
`v_reading`, `v_reading_current`, `v_data_freshness`, `v_dq_summary`, `v_sku_listing`, and the gold-compatible wide `v_wide` + `blinkit/zepto/instamart/jiomart/demo`.

## Operate
```bash
python -m sidnl.cli silver-apply        # apply sql/silver/*.sql in order (idempotent)
python -m sidnl.cli silver-test         # parser self-test
python -m sidnl.cli silver-refresh --brand "mr munchies"   # bronze -> silver, idempotent
python -m sidnl.cli silver-report       # freshness, DQ flags, listing %
```
## Known limits
Listing % is a floor (many scans `stopped_early`); only Blinkit is loaded; SOV needs competitor shelf data; sales/DRR/DOI/BE/PO/GRN/invoice metrics are not in scraped data (see `ref_metric_support`).
