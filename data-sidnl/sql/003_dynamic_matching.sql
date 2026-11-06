-- 003: Dynamic matching enhancements as per SIDNL System Design Report & Workflow Blueprint
-- Description & attribute based (No barcodes required):
-- 1. Adds L1, L2, L3 category columns for standardized category comparison
-- 2. Adds match_type to track match lineage (ATTRIBUTE_AUTO, ATTRIBUTE_REVIEW, NEW_MASTER)
-- 3. Adds indexes for fast multi-attribute candidate retrieval

alter table sidnl.product_features add column if not exists category_l1 text;
alter table sidnl.product_features add column if not exists category_l2 text;
alter table sidnl.product_features add column if not exists category_l3 text;
create index if not exists ix_pf_cat on sidnl.product_features (category_l1, category_l2);

alter table sidnl.master_products add column if not exists category_l1 text;
alter table sidnl.master_products add column if not exists category_l2 text;
alter table sidnl.master_products add column if not exists category_l3 text;
create index if not exists ix_master_brand on sidnl.master_products (brand);
create index if not exists ix_master_category on sidnl.master_products (category_l1, category_l2);

alter table sidnl.product_map add column if not exists match_type text default 'ATTRIBUTE';
create index if not exists ix_pm_match_type on sidnl.product_map (match_type);
