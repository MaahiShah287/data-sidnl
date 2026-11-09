-- DRAFT — NOT APPLIED. silver_051_shelf_view_product_key
-- Audit finding 3: v_shelf_by_sidnl reads fact_shelf_position (1M rows, 420 MB) twice,
-- once directly only to get product_key, because v_shelf_position does not expose it.
-- Change: append product_key as the LAST column of v_shelf_position (CREATE OR REPLACE
-- only allows new columns at the end; existing 38 columns keep name, type, order), then
-- rebuild v_shelf_by_sidnl on it without the self-join.
-- Semantics kept: every join stays INNER, so v_shelf_by_sidnl still returns only scoped
-- shelf rows whose product has an SI id. product_key is also appended to v_shelf_by_sidnl.
create or replace view silver.v_shelf_position with (security_invoker = true) as
select f.shelf_pos_key, f.source_record_id, f.snapshot_id, f.platform, f.l1_id, f.l2_id,
       f.store_key, f.city_slug, f.observed_at, f.obs_date,
       f.shelf_position, f.organic_position, f.is_ad, f.ad_type,
       f.brand_raw, f.brand_key, f.is_client_brand,
       f.platform_product_id, f.product_name, f.pack_raw,
       f.stock_status, f.inventory_units, f.inventory_is_capped,
       f.selling_price, f.mrp, f.discount_pct,
       f.shelf_cards_seen, f.shelf_total_items, f.shelf_complete,
       f.dq_status, f.dq_flags, f.loaded_at, f.etl_run_id,
       cs.l1_name, cs.l2_name, (cs.l1_name || ' > ') || cs.l2_name as category_path,
       ds.store_name, ct.city_name,
       f.product_key
from silver.fact_shelf_position f
join silver.category_scope cs on cs.platform = f.platform and cs.l1_id = f.l1_id and cs.l2_id = f.l2_id
left join silver.dim_store ds on ds.store_key = f.store_key
left join silver.dim_city  ct on ct.city_slug = f.city_slug;

create or replace view silver.v_shelf_by_sidnl with (security_invoker = true) as
select x.sidnl_id,
       v.shelf_pos_key, v.source_record_id, v.snapshot_id, v.platform, v.l1_id, v.l2_id,
       v.store_key, v.city_slug, v.observed_at, v.obs_date,
       v.shelf_position, v.organic_position, v.is_ad, v.ad_type,
       v.brand_raw, v.brand_key, v.is_client_brand,
       v.platform_product_id, v.product_name, v.pack_raw,
       v.stock_status, v.inventory_units, v.inventory_is_capped,
       v.selling_price, v.mrp, v.discount_pct,
       v.shelf_cards_seen, v.shelf_total_items, v.shelf_complete,
       v.dq_status, v.dq_flags, v.loaded_at, v.etl_run_id,
       v.l1_name, v.l2_name, v.category_path, v.store_name, v.city_name,
       v.product_key
from silver.v_shelf_position v
join silver.product_xref x on x.product_key = v.product_key;

comment on view silver.v_shelf_by_sidnl is
  'Category-shelf positions of a product, keyed by sidnl_id. Companion of v_reading_by_sidnl (store readings) and v_sidnl_product (one row per SI id).';
