-- rollback 001 + 002: remove the dash schema (6 tables + refresh function) and the one config row 001 added.
-- Roll back 003 first if it was applied: run_gold_pending calls dash.refresh().
drop schema if exists dash cascade;
delete from gold.cfg_threshold where key = 'low_stock_fe_units';
