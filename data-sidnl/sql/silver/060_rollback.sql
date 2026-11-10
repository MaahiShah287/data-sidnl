-- Rollback for silver_060_store_city_from_snapshots.
select cron.unschedule('sidnl-store-city');
do $rb$ declare r record; begin
  for r in select definition from ops.function_backup where tag = 'pre_silver_060' loop execute r.definition; end loop;
end $rb$;
update silver.fact_shelf_position f set city_slug = null from ops.store_city_filled s where f.store_key = s.store_key;
update silver.fact_product_reading f set city_slug = null from ops.store_city_filled s where f.store_key = s.store_key;
update silver.dim_store d set city_slug = null from ops.store_city_filled s where d.store_key = s.store_key;
drop function if exists silver.fill_store_cities();
drop index if exists silver.ix_fsp_null_city;
drop index if exists silver.ix_reading_null_city;
drop table ops.store_city_filled;
delete from ops.function_backup where tag = 'pre_silver_060';
update ops.pipeline_run set gold_status = 'pending' where run_id = (select max(run_id) from ops.pipeline_run where status = 'success');
