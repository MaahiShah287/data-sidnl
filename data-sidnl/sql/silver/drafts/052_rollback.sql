-- rollback 052: drop only the two constraints 052 added
alter table silver.fact_shelf_position  drop constraint if exists fact_shelf_position_category_scope_fkey;
alter table silver.fact_product_reading drop constraint if exists fact_product_reading_source_type_policy_fkey;
