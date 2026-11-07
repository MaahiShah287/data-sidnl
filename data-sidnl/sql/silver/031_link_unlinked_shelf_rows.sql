-- Applied to Supabase as migration 20261107183707 (silver_031_link_unlinked_shelf_rows).
-- Exported from supabase_migrations.schema_migrations.

update silver.fact_shelf_position f
   set product_key = dp.product_key
  from silver.dim_product dp
 where f.product_key is null and dp.platform = f.platform and dp.platform_product_id = f.platform_product_id;

do $do$
declare d text; d2 text;
begin
    d := pg_get_functiondef('silver.refresh_category_products(bigint,bigint,bigint)'::regprocedure);
    d2 := replace(d, 'and f.etl_run_id = p_run
       and dp.platform', 'and (f.etl_run_id = p_run or f.product_key is null)
       and dp.platform');
    if d2 = d then raise exception 'patch did not apply'; end if;
    execute d2;
end $do$;
