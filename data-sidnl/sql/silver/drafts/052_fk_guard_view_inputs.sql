-- DRAFT — NOT APPLIED. silver_052_fk_guard_view_inputs
-- Audit finding 2: v_reading INNER-joins freshness_policy and v_shelf_position INNER-joins
-- category_scope. Deleting a policy or scope row would silently hide its history from
-- those views (and from everything built on them). These FKs make such a delete fail
-- loudly instead. The views are not changed.
-- Checked live 2026-11-09: 0 orphan rows on both sides, so VALIDATE will pass.
-- To stop loading a category use category_scope.is_enabled = false, not DELETE.
-- NOT VALID + VALIDATE: the add is instant; validation scans under SHARE UPDATE EXCLUSIVE,
-- which does not block inserts. fact_shelf_position is ~1M rows, so expect a few seconds.
-- Run outside the minute cron if possible.
alter table silver.fact_product_reading
  add constraint fact_product_reading_source_type_policy_fkey
  foreign key (source_type) references silver.freshness_policy (source_type) not valid;
alter table silver.fact_product_reading
  validate constraint fact_product_reading_source_type_policy_fkey;

alter table silver.fact_shelf_position
  add constraint fact_shelf_position_category_scope_fkey
  foreign key (platform, l1_id, l2_id) references silver.category_scope (platform, l1_id, l2_id) not valid;
alter table silver.fact_shelf_position
  validate constraint fact_shelf_position_category_scope_fkey;
