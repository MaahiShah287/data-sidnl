-- rollback 053: recreate both views exactly as live on 2026-11-09 (definitions from pg_get_viewdef)
create view silver.v_category_shelf with (security_invoker = true) as
select x.sidnl_id, c.canonical_name, f.platform, f.brand_key, b.brand_name, dc.category_path,
       f.product_key, f.platform_product_id, f.product_name, f.pack_raw,
       ds.city_slug, ds.store_name, f.observed_at, f.obs_date,
       f.shelf_position, f.organic_position, f.is_ad, f.ad_type,
       f.stock_status, f.inventory_units, f.inventory_is_capped,
       f.selling_price, f.mrp, f.discount_pct, f.shelf_complete, f.dq_status
from silver.fact_shelf_position f
left join silver.product_xref x      on x.product_key = f.product_key
left join silver.canonical_product c on c.sidnl_id = x.sidnl_id
left join silver.dim_brand b         on b.brand_key = f.brand_key
left join silver.dim_store ds        on ds.store_key = f.store_key
left join silver.dim_product dp      on dp.product_key = f.product_key
left join silver.dim_category dc     on dc.category_key = dp.category_key;
comment on view silver.v_category_shelf is 'Category shelf readings (all brands) with the SI id of the product.';

create view silver.v_dim_product_sidnl with (security_invoker = true) as
select x.sidnl_id, x.match_status, x.match_method, x.score,
       d.product_key, d.platform, d.platform_product_id, d.brand_key, d.product_name, d.variant, d.product_type,
       d.pack_raw, d.size_value, d.size_unit, d.pack_count, d.total_content, d.category_key,
       d.listing_id, d.catalog_product_id, d.image_url, d.product_url, d.first_seen_at, d.last_seen_at
from silver.dim_product d
left join silver.product_xref x on x.product_key = d.product_key;
