-- =============================================================================
-- File:    first_party/003_rollback.sql
-- Reverts: first_party/003_workspace_scoping.sql
-- Additive changes only: columns are kept (nullable, harmless), views and the
-- config table are dropped. No data is deleted.
-- =============================================================================
drop view if exists dash.v_workspace_overview;
drop view if exists dash.v_workspace_sov_keyword;
drop view if exists dash.v_workspace_ads;
drop table if exists dash.cfg_workspace_account;
-- account_id columns intentionally KEPT (additive; dropping would lose nothing
-- today but dropping columns is destructive by policy). To fully revert run:
-- alter table public.fp_blinkit_ads drop column account_id;
-- alter table silver.fact_fp_ads     drop column account_id;
-- alter table dash.ads               drop column account_id;
-- alter table dash.overview          drop column account_id;
