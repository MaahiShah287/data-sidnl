-- dash_017_refresh_state_brand_default.sql
-- dash_brand_id_standard (2026-11-13 07:34 UTC) made dash.refresh_table_state.brand_id NOT NULL with no default, but the three
-- functions that write that table (dash.refresh_ads, dash.refresh_competitors, silver.run_gold_pending) do not set it, so every
-- gold refresh insert failed with a not-null violation from 07:34 on.
-- The tenant guard (dash.enforce_brand_id) forbids a nullable brand_id on any dash table, so the column stays NOT NULL and gets
-- the guard's own convention as a default: the only active tenant, "Mr Munchies" (dash.brand_registry). This is per-table refresh
-- bookkeeping, not brand data. When a second tenant is added, the three writers must pass brand_id explicitly (and this default
-- should be dropped).
alter table dash.refresh_table_state alter column brand_id set default '017ce4fc-99a0-4a4d-bae4-b171952df042'::uuid;
