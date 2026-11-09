-- Category-shelf positions of a product, keyed by sidnl_id. Companion of v_reading_by_sidnl and v_sidnl_product.
drop view if exists silver.v_shelf_by_sidnl;
create view silver.v_shelf_by_sidnl with (security_invoker = true) as
select x.sidnl_id, v.*
from silver.fact_shelf_position fs
join silver.product_xref x on x.product_key = fs.product_key
join silver.v_shelf_position v on v.shelf_pos_key = fs.shelf_pos_key;
