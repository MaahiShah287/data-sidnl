-- Rollback for silver_063_dead_letter.
-- After rollback, rows that are 'open' in ops.dead_letter are no longer excluded: the next load retries them and, if
-- they still fail, the whole scope fails again (pre-063 behaviour). Export ops.dead_letter first if you need the history.
select cron.unschedule('sidnl-dead-letter');
select cron.unschedule('sidnl-reconcile-coverage');
do $rb$ declare r record; begin
  for r in select definition from ops.function_backup where tag = 'pre_silver_063' loop execute r.definition; end loop;
end $rb$;
drop function if exists silver.reconcile_coverage();
drop function if exists silver.ignore_dead_letter(bigint, text, text);
drop function if exists silver.retry_dead_letters(boolean);
drop function if exists silver.load_category_range(text, text, text, bigint, bigint, bigint);
drop function if exists silver.load_category_chunk(text, text, text, bigint, bigint, bigint);
drop view if exists ops.v_dead_letter_summary;
drop table if exists ops.dead_letter;
delete from silver.sidnl_config where key in ('dead_letter_max_per_chunk', 'dead_letter_retry_minutes', 'dead_letter_max_retries');
delete from ops.function_backup where tag = 'pre_silver_063';
