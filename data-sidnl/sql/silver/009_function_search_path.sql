-- Pin search_path on every silver function (Supabase linter 0011). Idempotent.
do $$
declare f record;
begin
    for f in select p.oid::regprocedure as sig
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'silver' and p.prokind = 'f' loop
        execute format('alter function %s set search_path = silver, public, pg_temp', f.sig);
    end loop;
end $$;
