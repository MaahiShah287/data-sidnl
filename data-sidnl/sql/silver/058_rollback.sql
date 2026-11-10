-- Rollback for silver_058_auto_exact_match.
-- Stops the job and removes the function. Merges it already made are split back with the existing
-- silver.unmap_product (each product gets its own new SI id; the pipeline resequences SI ids on its next run).
select cron.unschedule('sidnl-auto-match');
select silver.unmap_product(product_key, 'rollback:silver_058')
  from silver.product_xref where reviewed_by = 'auto:exact_name_size';
drop function if exists silver.auto_approve_exact_matches();
delete from silver.sidnl_config where key = 'auto_match_exact_enabled';
update ops.pipeline_run set gold_status = 'pending'
 where run_id = (select max(run_id) from ops.pipeline_run where status = 'success');
