-- =============================================================================
-- File:    silver/008_security.sql
-- Purpose: Lock silver down. Silver is an internal layer: nothing in it should be
--          reachable through the Supabase Data API (anon / authenticated keys).
--          Service-role / postgres connections (the ETL, gold, dashboards via
--          server code) bypass RLS and keep working.
--
-- Run last (after every table exists). Idempotent.
-- =============================================================================

do $$
declare t record;
begin
    for t in select c.relname
             from pg_class c join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'silver' and c.relkind in ('r', 'p') loop
        execute format('alter table silver.%I enable row level security', t.relname);
    end loop;

    if exists (select 1 from pg_roles where rolname = 'anon') then
        revoke all on schema silver from anon;
        revoke all on all tables in schema silver from anon;
        revoke all on all functions in schema silver from anon;
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then
        revoke all on schema silver from authenticated;
        revoke all on all tables in schema silver from authenticated;
        revoke all on all functions in schema silver from authenticated;
    end if;
end $$;
