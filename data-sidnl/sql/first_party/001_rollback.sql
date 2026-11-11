-- =============================================================================
-- File:    first_party/001_rollback.sql
-- Reverts: first_party/001_fp_blinkit_ads.sql
-- =============================================================================
-- [ADMIN] select cron.unschedule('sidnl-ads-refresh');

drop view if exists dash.v_sov_keyword;
drop function if exists dash.refresh_ads();
drop function if exists silver.load_fp_ads();
drop table if exists silver.fact_fp_ads;
drop table if exists public.fp_blinkit_ads;
drop table if exists public.fp_load_file;
