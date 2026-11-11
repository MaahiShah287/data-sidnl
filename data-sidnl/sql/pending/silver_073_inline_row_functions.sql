-- silver_073_inline_row_functions
-- Performance: the per-row quality functions run once or more for every shelf row a load touches (2.09 M rows in a
-- full reload). A SQL function with a `SET search_path` clause can never be inlined by the planner, so each row paid
-- full function calls. These six functions only call built-ins (lower, btrim, regexp, array ops, casts), which
-- PostgreSQL always resolves from pg_catalog first, so the clause protects nothing here; removing it lets them inline.
-- Measured on production rows (rolled-back test, 2026-11-11): the shelf loader's quality expression on 100,000 rows
-- 4.51 s -> 1.49 s. The forced full reload after silver_069 took 509 s against cron's 600 s limit; this removes about
-- a minute of it. Behaviour is unchanged: silver.selftest_pure() 24/24 before and after.
-- Supabase's linter will list these six under "function search path mutable"; that is expected and harmless here.

alter function silver.reading_dq(boolean, boolean, timestamptz, text, integer, numeric, numeric) reset search_path;
alter function silver.dq_status(text[]) reset search_path;
alter function silver.map_stock_status(text) reset search_path;
alter function silver.read_flags(text, boolean, boolean) reset search_path;
alter function silver.read_stock_status(text, text, boolean, boolean) reset search_path;
alter function silver.safe_int(text) reset search_path;
