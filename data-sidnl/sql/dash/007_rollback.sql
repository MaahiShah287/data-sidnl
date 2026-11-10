-- Rollback for dash_007_visibility_full_rebuild: restore run_gold_pending as of dash_006 (3-day visibility window).
-- Note: rolling back brings back stale SI ids in visibility rows older than 3 days after the next renumbering.
do $rb$
declare r record;
begin
    for r in select definition from ops.function_backup where tag = 'pre_dash_007' loop
        execute r.definition;
    end loop;
end $rb$;
delete from silver.sidnl_config where key = 'gold_visibility_days';
delete from ops.function_backup where tag = 'pre_dash_007';
-- Verify: md5(pg_get_functiondef('silver.run_gold_pending()'::regprocedure)) = 'c907f4c46b44829b836aeb54b93f6000'
