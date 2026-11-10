-- silver_058_auto_exact_match
-- docs/silver/CANONICAL_MAPPING_AUDIT_2026-11-10.md D3.
-- Cross-platform matches that are certain wait in silver.match_review_queue only because platforms write the pack
-- differently (Zepto "1 pack (1.25 kg)" vs Blinkit "1.25 kg"). This automation approves a pending review ONLY when
-- every one of these holds (no fuzzy score is used):
--   * same brand_key (not null)
--   * identical product name after lower-case, trim and collapsing spaces
--   * identical parsed size_value, size_unit and pack_count (not null)
--   * the product is alone in its current SI id, and the target SI id has no product on the same platform
--   * every product already in the target SI id is such an exact twin
-- Anything else stays in the queue (fuzzy suggestions are known to be wrong at score 0.975). Approval goes through
-- the existing silver.approve_match -> silver.merge_canonical (which itself refuses same-platform merges). SI ids are
-- resequenced later by the existing pipeline. After any approval the latest successful run is re-queued for gold.
-- Runs every 10 minutes as cron job sidnl-auto-match; switch off with sidnl_config.auto_match_exact_enabled = 0.

insert into silver.sidnl_config (key, value_num, description) values
  ('auto_match_exact_enabled', 1, '1 = sidnl-auto-match approves pending reviews that are exact cross-platform twins (same brand, same normalized name, same parsed size/unit/pack); 0 = off. Fuzzy matches are never auto-approved.')
on conflict (key) do nothing;

create or replace function silver.auto_approve_exact_matches()
 returns jsonb
 language plpgsql
 set search_path to 'silver', 'ops', 'public', 'extensions', 'pg_temp'
as $function$
declare
    r record; v_ok bigint[] := '{}'; v_skip jsonb := '[]'::jsonb;
begin
    if coalesce(silver.cfg('auto_match_exact_enabled'), 0) <> 1 then
        return jsonb_build_object('status', 'disabled');
    end if;
    if not pg_try_advisory_xact_lock(727100) then
        return jsonb_build_object('status', 'skipped', 'reason', 'pipeline run in progress');
    end if;

    for r in
        select q.review_id
          from silver.match_review_queue q
          join silver.product_xref x  on x.product_key = q.product_key
          join silver.dim_product d   on d.product_key = q.product_key
         where q.status = 'pending'
           and d.brand_key is not null and d.size_value is not null and d.size_unit is not null and d.pack_count is not null
           and x.sidnl_id <> q.suggested_sidnl_id
           and (select count(*) from silver.product_xref x1 where x1.sidnl_id = x.sidnl_id) = 1
           and exists (select 1 from silver.product_xref x2 where x2.sidnl_id = q.suggested_sidnl_id)
           and not exists (select 1 from silver.product_xref x2 join silver.dim_product d2 using (product_key)
                            where x2.sidnl_id = q.suggested_sidnl_id and d2.platform = d.platform)
           and not exists (select 1 from silver.product_xref x2 join silver.dim_product d2 using (product_key)
                            where x2.sidnl_id = q.suggested_sidnl_id
                              and not (d2.brand_key = d.brand_key
                                       and regexp_replace(lower(btrim(d2.product_name)), '\s+', ' ', 'g')
                                         = regexp_replace(lower(btrim(d.product_name)), '\s+', ' ', 'g')
                                       and (d2.size_value, d2.size_unit, d2.pack_count) = (d.size_value, d.size_unit, d.pack_count)))
         order by q.review_id
    loop
        begin
            perform silver.approve_match(r.review_id, 'auto:exact_name_size');
            v_ok := v_ok || r.review_id;
        exception when others then
            v_skip := v_skip || jsonb_build_object('review_id', r.review_id, 'error', sqlerrm);
        end;
    end loop;

    if cardinality(v_ok) > 0 then
        update ops.pipeline_run set gold_status = 'pending'
         where run_id = (select max(run_id) from ops.pipeline_run where status = 'success') and gold_status is distinct from 'pending';
    end if;
    return jsonb_build_object('status', 'ok', 'approved', cardinality(v_ok), 'review_ids', to_jsonb(v_ok), 'skipped', v_skip);
end $function$;

comment on function silver.auto_approve_exact_matches() is
  'sidnl-auto-match: approves only exact cross-platform twins from match_review_queue (see silver_058). Fuzzy matches stay for review.';

select cron.schedule('sidnl-auto-match', '*/10 * * * *',
                     $cmd$set statement_timeout = '120s'; select silver.auto_approve_exact_matches()$cmd$);
