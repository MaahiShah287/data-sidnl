-- =============================================================================
-- File:    063_rollback.sql
-- Reverts: 20261110121500_silver_063_dead_letter.sql
-- Dead-letter rows are never deleted by the system; if any exist they are
-- preserved to ops.dead_letter_backup before dropping.
-- =============================================================================

do $$
begin
  if to_regclass('ops.dead_letter') is not null
     and exists (select 1 from ops.dead_letter) then
    create table if not exists ops.dead_letter_backup as
      select * from ops.dead_letter;
  end if;
end $$;

drop view if exists ops.v_scope_health;
drop view if exists ops.v_dead_letter_open;
drop function if exists silver.retry_dead_letters(p_force bool);
drop function if exists silver.isolate_bad_rows(text, text, bigint, bigint, text, int);
drop table if exists ops.dead_letter;

delete from silver.sidnl_config
 where key in ('dead_letter_retry_minutes','dead_letter_max_retries');

-- NOTE: if the Phase 3 loader predicates were added to the live loaders,
-- revert those create-or-replace functions from ops.function_backup too.
