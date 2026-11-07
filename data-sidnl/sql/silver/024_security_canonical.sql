-- =============================================================================
-- File:    silver/024_security_canonical.sql
-- Purpose: Same lock-down as 008 for everything added by 020-023.
--          RLS on every silver table, no Data API access for anon / authenticated.
--          Run last. Idempotent.
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
        revoke all on all sequences in schema silver from anon;
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then
        revoke all on schema silver from authenticated;
        revoke all on all tables in schema silver from authenticated;
        revoke all on all functions in schema silver from authenticated;
        revoke all on all sequences in schema silver from authenticated;
    end if;
end $$;
