-- =============================================================================
-- File:    silver/006_compat_views.sql
-- Purpose: Backward-compatible WIDE layer.
--
-- sql/gold/002_gold_base_union.sql and Rag/sql/01_views.sql + 03_roles.sql were
-- written against wide per-platform tables  silver.blinkit / zepto / instamart /
-- jiomart / demo  (one row per reading, ~65 columns).  Those tables do not exist
-- in this project; the star schema replaces them.  These views re-create the
-- exact wide contract on top of the star schema so gold + RAG run UNCHANGED.
--
--   source_type   stock_check -> 'observation'      (gold: OSA / inventory source)
--                 brand_search, category_shelf -> 'shelf_position' (gold: SOV / rank source)
--   listing_id    = the product's tracked listing id (stable across sources), so
--                   COALESCE(listing_id::text, platform_product_id) is one key per SKU
--   store_id      = public.stores.id (source_store_id), same id the bronze tables use
--   pack_size     = pack text as displayed; quantity/quantity_unit = parsed size
--   NULL columns  = things scraping cannot provide (pincode, ETA, description, ...)
-- =============================================================================

create or replace view silver.v_wide as
select f.reading_key                                               as id,
       p.platform,
       case f.source_type when 'stock_check' then 'observation' else 'shelf_position' end as source_type,
       f.source_record_id,
       p.listing_id,
       p.catalog_product_id                                        as product_id,
       s.source_store_id                                           as store_id,
       f.run_id,
       f.scrape_id                                                 as scrape_run_id,
       c.l1_id, c.l1_name   as l1_category,
       c.l2_id, c.l2_name   as l2_category,
       c.l3_id, c.l3_name   as l3_category,
       c.category_path,
       p.platform_product_id,
       p.platform_product_id                                       as sku_code,
       p.product_name,
       p.product_name                                              as sku_name,
       b.brand_name                                                as brand,
       p.variant,
       null::text                                                  as product_description,
       p.product_url,
       p.image_url,
       p.pack_raw                                                  as pack_size,
       p.size_unit                                                 as pack_unit,
       p.size_value                                                as quantity,
       p.size_unit                                                 as quantity_unit,
       f.mrp,
       f.selling_price                                             as sale_price,
       f.discount_amount,
       f.discount_pct                                              as discount_percentage,
       round(f.selling_price / nullif(p.total_content, 0), 4)      as price_per_unit,
       'INR'::text                                                 as currency,
       f.inventory_units                                           as inventory,
       f.inventory_is_capped                                       as inventory_capped,
       f.inventory_units                                           as available_quantity,
       f.is_available                                              as availability,
       f.stock_status,
       case when f.inventory_units is null then null
            when f.inventory_is_capped then 'capped' else 'exact' end as inventory_status,
       null::int                                                   as delivery_eta_minutes,
       f.search_position                                           as "position",
       f.organic_position,
       f.is_ad,
       f.ad_type,
       p.product_type,
       s.store_external_id,
       s.store_name,
       ct.city_name                                                as city,
       f.city_slug,
       ct.state,
       null::text                                                  as pincode,
       s.latitude,
       s.longitude,
       f.observed_at,
       f.observed_at                                               as scraped_at,
       f.loaded_at                                                 as transformed_at,
       null::text                                                  as source_url,
       sc.scan_status                                              as scrape_status,
       null::text                                                  as scrape_backend,
       null::text                                                  as scrape_run_status,
       f.dq_status                                                 as data_quality_status,
       to_jsonb(f.dq_flags)                                        as validation_errors,
       null::jsonb                                                 as raw_details,
       jsonb_build_object('source_type', f.source_type, 'source_table', f.source_table,
                          'job_ref', f.job_ref, 'etl_run_id', f.etl_run_id) as source_metadata,
       array[f.source_record_id]                                   as bronze_record_ids
from silver.fact_product_reading f
join silver.dim_product p        on p.product_key = f.product_key
join silver.dim_brand b          on b.brand_key = p.brand_key
left join silver.dim_category c  on c.category_key = p.category_key
left join silver.dim_store s     on s.store_key = f.store_key
left join silver.dim_city ct     on ct.city_slug = f.city_slug
left join silver.fact_store_scan sc on sc.snapshot_id = f.snapshot_id and f.source_type = 'brand_search';
comment on view silver.v_wide is 'Wide, gold/RAG-compatible projection of the star schema (see header of 006_compat_views.sql).';

create or replace view silver.blinkit   as select * from silver.v_wide where platform = 'blinkit';
create or replace view silver.zepto     as select * from silver.v_wide where platform = 'zepto';
create or replace view silver.instamart as select * from silver.v_wide where platform = 'instamart';
create or replace view silver.jiomart   as select * from silver.v_wide where platform = 'jiomart';
create or replace view silver.demo      as select * from silver.v_wide where platform = 'demo';

comment on view silver.blinkit   is 'Compat: wide per-platform silver contract used by gold/RAG. Source = silver.v_wide.';
comment on view silver.zepto     is 'Compat: wide per-platform silver contract used by gold/RAG. Source = silver.v_wide.';
comment on view silver.instamart is 'Compat: wide per-platform silver contract used by gold/RAG. Source = silver.v_wide.';
comment on view silver.jiomart   is 'Compat: wide per-platform silver contract used by gold/RAG. Source = silver.v_wide.';
comment on view silver.demo      is 'Compat: always empty (demo data is excluded from silver by design).';
