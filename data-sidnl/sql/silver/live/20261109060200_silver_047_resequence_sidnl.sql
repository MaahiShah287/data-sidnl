-- SI ids are kept strictly A-Z by product name. Renumbering happens in one transaction:
-- FKs are made deferrable, ids move to a temporary high band, then to their final value.
alter table silver.product_xref        alter constraint product_xref_sidnl_id_fkey deferrable initially immediate;
alter table silver.match_review_queue  alter constraint match_review_queue_suggested_sidnl_id_fkey deferrable initially immediate;
alter table silver.canonical_product   alter constraint canonical_product_merged_into_fkey deferrable initially immediate;

create or replace function silver.resequence_sidnl()
returns integer
language plpgsql
set search_path to 'silver', 'public', 'pg_temp'
as $fn$
declare n_changed int; n_total int;
begin
    perform pg_advisory_xact_lock(727100);   -- same lock as run_pipeline (re-entrant inside it)
    set constraints all deferred;

    -- retired ids lose their meaning once ids move: point anything still using them at the survivor, then drop them
    update silver.product_xref x set sidnl_id = silver.sidnl_resolve(x.sidnl_id)
     where x.sidnl_id in (select sidnl_id from silver.canonical_product where not is_active);
    update silver.match_review_queue q set suggested_sidnl_id = silver.sidnl_resolve(q.suggested_sidnl_id)
     where q.suggested_sidnl_id in (select sidnl_id from silver.canonical_product where not is_active);

    drop table if exists _si_map;
    create temp table _si_map on commit drop as
    select sidnl_id as old_id,
           row_number() over (order by lower(canonical_name), brand_key, size_value nulls first, pack_count,
                                       substr(sidnl_id, 3)::bigint)::int as new_n
      from silver.canonical_product where is_active;

    select count(*) filter (where old_id <> silver.format_sidnl_id(new_n)), count(*) into n_changed, n_total from _si_map;

    if n_changed = 0 and not exists (select 1 from silver.canonical_product where not is_active) then
        return 0;
    end if;

    delete from silver.canonical_product where not is_active;

    -- phase 1: move to a temporary band (1,000,000+) so no id collides while renumbering
    update silver.canonical_product c set sidnl_id = 'SI' || (1000000 + m.new_n) from _si_map m where c.sidnl_id = m.old_id;
    update silver.product_xref x set sidnl_id = 'SI' || (1000000 + m.new_n) from _si_map m where x.sidnl_id = m.old_id;
    update silver.match_review_queue q set suggested_sidnl_id = 'SI' || (1000000 + m.new_n) from _si_map m where q.suggested_sidnl_id = m.old_id;

    -- phase 2: final ids
    update silver.canonical_product c set sidnl_id = silver.format_sidnl_id(m.new_n) from _si_map m where c.sidnl_id = 'SI' || (1000000 + m.new_n);
    update silver.product_xref x set sidnl_id = silver.format_sidnl_id(m.new_n) from _si_map m where x.sidnl_id = 'SI' || (1000000 + m.new_n);
    update silver.match_review_queue q set suggested_sidnl_id = silver.format_sidnl_id(m.new_n) from _si_map m where q.suggested_sidnl_id = 'SI' || (1000000 + m.new_n);

    perform setval('silver.sidnl_id_seq', greatest(n_total, 1), n_total > 0);
    return n_changed;
end $fn$;
comment on function silver.resequence_sidnl() is 'Keeps SI ids strictly alphabetical by canonical product name. Called by run_pipeline after matching; no-op when already ordered.';

-- hook: run after sync_canonical_attrs inside silver.run_pipeline
do $$
declare d text; marker text := $m$v_steps := v_steps || jsonb_build_object('sync_canonical_attrs', jsonb_build_object('ok', true, 'updated', silver.sync_canonical_attrs()));$m$;
begin
  d := pg_get_functiondef('silver.run_pipeline(boolean,text)'::regprocedure);
  if position(marker in d) = 0 then raise exception 'marker not found in run_pipeline'; end if;
  if position('resequence_sidnl' in d) > 0 then return; end if;
  d := replace(d, marker, marker || E'\n        v_steps := v_steps || jsonb_build_object(''resequence_sidnl'', jsonb_build_object(''ok'', true, ''renumbered'', silver.resequence_sidnl()));');
  execute d;
end $$;
