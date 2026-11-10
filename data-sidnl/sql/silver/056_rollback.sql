-- Rollback for silver_056_parse_pack_counts.
-- 1. Restores silver.parse_pack and silver.selftest_parser to their exact pre-056 text (saved in ops.function_backup,
--    tag pre_silver_056).
-- 2. Re-derives size/unit/pack for silver.dim_product with the restored parser. Before 056 every row equalled
--    parse_pack(pack_raw), so this returns every row to its pre-056 values.
-- 3. Queues one forced pipeline job so canonical attributes, SI order and gold follow, exactly as 056 did.
-- Apply as a Supabase migration named silver_056r_rollback_parse_pack_counts if ever needed.

do $rb$
declare r record;
begin
    for r in select definition from ops.function_backup where tag = 'pre_silver_056' loop
        execute r.definition;
    end loop;
end $rb$;

update silver.dim_product d
   set size_value = pk.size_value, size_unit = pk.size_unit, pack_count = pk.pack_count
  from silver.dim_product d2 cross join lateral silver.parse_pack(d2.pack_raw) pk
 where d2.product_key = d.product_key
   and (d.size_value, d.size_unit, d.pack_count) is distinct from (pk.size_value, pk.size_unit, pk.pack_count);

insert into ops.pipeline_job (job_type, trigger, force, status) values ('regular', 'silver_056r', true, 'queued');

delete from ops.function_backup where tag = 'pre_silver_056';

-- Verify: md5(pg_get_functiondef('silver.parse_pack(text)'::regprocedure)) = '872db3fa441e361ed86a9bc376abb0b0'
--         md5(pg_get_functiondef('silver.selftest_parser()'::regprocedure)) = '55cc3161c925740a6a99a26f05bffdd0'
