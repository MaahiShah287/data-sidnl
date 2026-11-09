-- DRAFT — NOT APPLIED. silver_053_retire_unused_views
-- Audit §6/§8: these two views feed no PDF metric and have no dependent view or function
-- (pg_depend + function-body search) and no reference anywhere in this repo:
--   v_category_shelf    -- duplicate of v_shelf_by_sidnl (shelf rows + SI id)
--   v_dim_product_sidnl -- listing-grain xref join; nothing reads it
-- BEFORE APPLYING: check the Supabase API / Postgres logs and any BI tool for direct
-- queries of these names over the last 30 days. The audit could not see external callers.
-- Deliberately NOT dropped: demo, instamart, jiomart. They are empty, but the RAG SQL
-- (Rag/sql/01_views.sql, 03_roles.sql) and sql/gold/002_gold_base_union.sql reference
-- them by name. Retire them together with those scripts.
-- RESTRICT (the default) makes the drop fail if anything was added that depends on them.
drop view silver.v_category_shelf restrict;
drop view silver.v_dim_product_sidnl restrict;
