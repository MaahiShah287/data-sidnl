-- rollback 051: a view cannot lose a column via CREATE OR REPLACE, so drop and recreate both
-- exactly as they are live before 051 (v_shelf_by_sidnl = live migration 046).
-- Nothing else depends on these two views (checked in pg_depend on 2026-11-09).
drop view if exists silver.v_shelf_by_sidnl;
drop view if exists silver.v_shelf_position;

create view silver.v_shelf_position with (security_invoker = true) as
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
       ds.store_name, ct.city_name
from silver.fact_shelf_position f
join silver.category_scope cs on cs.platform = f.platform and cs.l1_id = f.l1_id and cs.l2_id = f.l2_id
left join silver.dim_store ds on ds.store_key = f.store_key
left join silver.dim_city  ct on ct.city_slug = f.city_slug;

create view silver.v_shelf_by_sidnl with (security_invoker = true) as
select x.sidnl_id, v.*
from silver.fact_shelf_position fs
join silver.product_xref x on x.product_key = fs.product_key
join silver.v_shelf_position v on v.shelf_pos_key = fs.shelf_pos_key;

comment on view silver.v_shelf_by_sidnl is
  'Category-shelf positions of a product, keyed by sidnl_id. Companion of v_reading_by_sidnl (store readings) and v_sidnl_product (one row per SI id).';
