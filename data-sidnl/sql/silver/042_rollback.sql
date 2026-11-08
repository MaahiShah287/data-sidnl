-- restore 039 version of record_storage_snapshot (no alert call), then drop 042 objects (all additive, no data loss)
create or replace function silver.record_storage_snapshot() returns integer language plpgsql set search_path to 'silver','public','pg_temp' as $f$
declare v_d date := (now() at time zone 'Asia/Kolkata')::date; v_n int;
begin
    if exists (select 1 from silver.storage_snapshot where snapshot_date = v_d) then return 0; end if;
    insert into silver.storage_snapshot (snapshot_date, relation, total_bytes, table_bytes, index_bytes, live_rows, dead_rows, db_bytes)
    select v_d, n.nspname || '.' || c.relname, pg_total_relation_size(c.oid), pg_relation_size(c.oid), pg_indexes_size(c.oid),
           s.n_live_tup, s.n_dead_tup, pg_database_size(current_database())
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
      left join pg_stat_all_tables s on s.relid = c.oid
     where c.relkind = 'r' and n.nspname in ('silver', 'public') and pg_total_relation_size(c.oid) > 1024 * 1024
    on conflict do nothing;
    get diagnostics v_n = row_count; return v_n;
end $f$;
drop view if exists silver.v_storage_projection;
drop function if exists silver.check_storage_alert();
drop function if exists silver.storage_usage();
drop table if exists silver.storage_alert_log;
delete from silver.sidnl_config where key in ('storage_plan_gb','storage_warn_pct','storage_crit_pct');
