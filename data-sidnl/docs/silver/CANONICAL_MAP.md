# Canonical product map (SI ids) and the automatic pipeline

## The idea
One real-world product = one `sidnl_id` (`SI001`, `SI002`, ... `SI999`, `SI1000`) on every platform.
The same product's Blinkit id and Zepto id both point to the same SI id.

```
silver.dim_product (platform + platform_product_id)
      └─ silver.product_xref        product_key -> sidnl_id, method, score, score_detail
              └─ silver.canonical_product   one row per SI id (attributes follow the anchor member)
silver.match_review_queue            0.75-0.90 suggestions awaiting a human
```

## Read the map
```sql
select * from silver.v_canonical_product_map;      -- one row per SI id, display category names, platform ids
select * from silver.v_canonical_brand_summary;    -- products per brand
```
Categories (L1 > L2 > L3) come from the deepest thing the scrapers captured: the product-page breadcrumb
(`platform_listings.categories`, L1-L3) beats the shelf read (L1-L2 only). `silver.enrich_product_categories()`
applies this on every pipeline run. A category column is NULL only when nothing was scraped for that level;
`product_type` (the platform's own product type, e.g. "Cola Soft Drink") is shown separately and is not a category.

## Find everything about a product
```sql
select silver.sidnl_everything('SI001');            -- every silver + gold table, every platform (jsonb)
select * from silver.sidnl_find('<name words>');     -- by name, platform product id, or SI id
select * from silver.v_sidnl_product;                -- SI id + product id on each platform
select * from silver.v_reading_by_sidnl where sidnl_id = 'SI001';
```
`sidnl_everything` discovers tables from the catalog (any silver/gold base table with `product_key`, or
`platform` + `platform_product_id`), so new fact and gold tables are included automatically. `p_row_limit`
(default 1000) caps rows per table; `row_count` is always the true total. Merged/retired ids still resolve.

## How two listings are matched (port of match.py / normalize.py)
| Check | What | Weight |
|---|---|---|
| 1 Lexical | name token-set similarity (trigram), brand | 35% + 25% |
| 2 Semantic | size/pack agreement, variant (+ synonyms from `ref_variant_synonym`), category L1-L3 | 20% + 15% + 5% |
| 3 Strict rules | pack count differs, size differs > 5%, brand conflict, opposing variant -> never auto-map | - |

Weights are re-normalised over attributes both sides have. Decision, in this order:
1. Client catalog link (`public.products`, same `catalog_product_id` on two platforms) -> same SI id, score 1.0.
2. **Exact match** (migration 032): same brand + same normalised name + same normalised pack
   (`silver.exact_key()`: lower-case, letters/digits only) -> same SI id, on any platform, *including a second
   id on the same platform* (Blinkit sometimes lists one product under two ids). Method `EXACT_NAME_PACK`.
3. Fuzzy score `>= 0.75` (or a rule conflict) -> the product gets its own SI id and a row in
   `match_review_queue` for a human. With `sidnl_config.auto_merge_fuzzy = 1` a score `>= 0.90` whose rules pass
   merges automatically instead; the default is 0 because the scorer gave 1.0 to different flavours
   (Lemon vs Lime, Cherry vs Cherry Float Zero).
4. Below 0.75 -> new SI id.

A brand legitimately repeats in the map once per SKU: every flavour x size x pack count is its own product
and its own SI id. Use `silver.v_canonical_brand_summary` for brand-level counts. Weights, thresholds, noise words and synonyms live in `sidnl_config`, `ref_noise_word`,
`ref_variant_synonym`: edit rows, no deploy.

Deviation from `match.py`: when only one side has a category the category score is neutral (0.5), not 0.
"Semantic" means these meaning checks; there are no embeddings (RAG is out of scope for now).

## Review
```sql
select * from silver.match_review_queue where status = 'pending';
select silver.approve_match(<review_id>);   -- merges the two SI ids
select silver.reject_match(<review_id>);    -- keeps them separate
select silver.merge_canonical('SI007', 'SI001');
select silver.unmap_product(<product_key>); -- split a wrong merge into a new SI id
```

## Automation
Nothing needs to be run by hand. New shelf categories are registered automatically once they were read OK at
`sidnl_config.category_min_stores` (10) distinct dark stores, with or without a finished sweep
(`silver.register_category_scopes()`).
pg_cron runs `silver.run_pipeline()` every minute. It checks `max(id)` of six bronze tables
(`silver.pipeline_source`); with nothing new it returns `idle` and writes nothing. Otherwise:
`refresh_brand` (parser + cleaning, per brand, failures isolated) -> `refresh_category_market` ->
`map_new_products` -> `sync_canonical_attrs` -> `gold.refresh_all`. Watermarks advance only after a fully
successful run. A minimum gap of `pipeline_min_interval_seconds` (600) separates runs; a forced run
(`silver.run_pipeline(true)`) happens daily at 00:05 IST so date-based gold tables roll over.

```sql
select * from silver.v_pipeline_status;      -- health
select * from silver.pipeline_run order by run_id desc limit 5;   -- per-step timings and errors
select silver.run_pipeline(true);            -- run now
select cron.unschedule('sidnl-pipeline');    -- pause automation
select * from silver.selftest_matcher();     -- matcher tests, every row must be ok = true
```

## To onboard a new brand
`insert into silver.brand_scope (brand_key, brand_name, company_name) values (...)` plus a `silver.dim_brand`
row is created by the next run; its products then flow through parsing, SI ids and gold automatically.

## Known limits
- `refresh_brand` re-reads a brand's whole history (~90 s today); a true incremental load is the next optimisation.
- Canonical mapping covers `dim_product` (tracked brands). Competitor cards in `fact_shelf_position` have no
  `dim_product` row yet, so they have no SI id until their brands are added to `brand_scope`.
- `gold.price_parity_platform` still keys on `catalog_product_id`; switching it to `sidnl_id` is a small follow-up.
- L3 exists only where a product page was scraped (breadcrumb). Shelf reads carry L1-L2 only, so most
  products have no L3 until their product pages are scraped. Client products that appeared only in brand search
  have no category at all.
- An SI id may now hold more than one id on a platform (exact duplicates); `v_sidnl_product.platform_ids` shows
  the oldest id, `platform_id_aliases` lists all. `silver.merge_canonical` still refuses same-platform merges.
- Only Blinkit is loaded, so every SI id currently has one platform. The cross-platform path has not yet run on
  real data; it will the first time a second platform's products land in `dim_product`.
- Add spelling variants you actually see across platforms to `silver.ref_variant_synonym`; none are pre-seeded
  beyond `config/matching.yaml`.
