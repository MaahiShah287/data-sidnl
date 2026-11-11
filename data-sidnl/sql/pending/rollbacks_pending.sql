-- Rollbacks for the pending migrations, newest first. Move each block into sql/rollbacks.sql when its migration is
-- applied.

-- ===================================================================================== rollback silver_073
alter function silver.reading_dq(boolean, boolean, timestamptz, text, integer, numeric, numeric) set search_path to 'silver', 'ops', 'public', 'pg_temp';
alter function silver.dq_status(text[]) set search_path to 'silver', 'ops', 'public', 'pg_temp';
alter function silver.map_stock_status(text) set search_path to 'silver', 'ops', 'public', 'pg_temp';
alter function silver.read_flags(text, boolean, boolean) set search_path to 'silver', 'pg_temp';
alter function silver.read_stock_status(text, text, boolean, boolean) set search_path to 'silver', 'pg_temp';
alter function silver.safe_int(text) set search_path to 'silver', 'pg_temp';
