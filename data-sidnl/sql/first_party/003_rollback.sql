-- =============================================================================
-- File:    first_party/003_rollback.sql
-- Reverts: first_party/003_workspace_scoping.sql (v2)
-- Purely additive objects: views + one config table. No data is deleted.
-- =============================================================================
drop view if exists dash.v_workspace_overview;
drop view if exists dash.v_workspace_sov_keyword;
drop view if exists dash.v_workspace_ads;
drop table if exists dash.cfg_workspace_map;
