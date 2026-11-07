-- =============================================================================
-- File:    silver/023_pipeline_automation.sql
-- Purpose: Fully automatic bronze -> silver -> canonical map -> gold.
--
--   pg_cron (every minute) -> silver.run_pipeline()
--       1. looks for new bronze rows (cheap max(id) check per source table)
--       2. silver.refresh_brand() for every enabled brand   (parser + cleaning, per-brand isolated)
--       3. silver.refresh_category_market()                  (market-wide shelf)
--       4. silver.map_new_products()                         (SI ids: lexical + semantic + safety rules)
--       5. silver.sync_canonical_attrs()
--       6. gold.refresh_all()                                (all PDF metrics)
--   Idle minutes cost six index lookups and write nothing.
--
-- Why polling and not row triggers: the scrapers insert hundreds of thousands of rows
-- (shelf_positions alone is 500k+); a trigger on that hot path would slow every insert.
-- Watermarks only advance after a fully successful run, so a failed run is retried.
-- =============================================================================

create table if not exists silver.pipeline_source (
    source_schema  text not null,
    source_table   text not null,
    id_column      text not null default 'id',
    last_seen_id   bigint not null default 0,
    primary key (source_schema, source_table)
);
comment on table silver.pipeline_source is 'Bronze tables watched for new rows; last_seen_id is the watermark of the last successful pipeline run.';

insert into silver.pipeline_source (source_schema, source_table) values
    ('public','observations'), ('public','search_cards'), ('public','search_snapshots'),
    ('public','shelf_positions'), ('public','shelf_snapshots'), ('public','platform_listings')
on conflict do nothing;

create table if not exists silver.pipeline_run (
    run_id      bigint generated always as identity primary key,
    started_at  timestamptz not null default now(),
    finished_at timestamptz,
    trigger     text not null,
    status      text not null default 'running' check (status in ('running','success','partial')),
    new_data    jsonb not null default '{}'::jsonb,     -- source table -> new max id
    steps       jsonb not null default '{}'::jsonb      -- per step: ok / seconds / stats / error
);
comment on table silver.pipeline_run is 'One row per pipeline run that actually did work. Idle ticks are not logged.';

create or replace function silver.run_pipeline(p_force boolean default false, p_trigger text default 'manual')
returns jsonb
language plpgsql
set search_path = silver, public, extensions, pg_temp
set statement_timeout = '600s'
as $$
declare
    s record; b record; v_max bigint;
    v_new jsonb := '{}'::jsonb; v_maxes jsonb := '{}'::jsonb; v_steps jsonb := '{}'::jsonb;
    v_unmapped int; v_run bigint; v_failed boolean := false; v_t timestamptz;
    v_min int := coalesce(silver.cfg('pipeline_min_interval_seconds'), 120)::int;
    v_tmp jsonb;
begin
    if not pg_try_advisory_xact_lock(727100) then
        return jsonb_build_object('status', 'skipped', 'reason', 'another run is in progress');
    end if;

    -- 1. detect new bronze data
    for s in select * from silver.pipeline_source loop
        execute format('select coalesce(max(%I), 0) from %I.%I', s.id_column, s.source_schema, s.source_table) into v_max;
        v_maxes := v_maxes || jsonb_build_object(s.source_schema || '.' || s.source_table, v_max);
        if v_max > s.last_seen_id then
            v_new := v_new || jsonb_build_object(s.source_schema || '.' || s.source_table, v_max);
        end if;
    end loop;
    select count(*) into v_unmapped from silver.dim_product p
     where not exists (select 1 from silver.product_xref x where x.product_key = p.product_key);

    if not p_force and v_new = '{}'::jsonb and v_unmapped = 0 then
        return jsonb_build_object('status', 'idle');
    end if;
    if not p_force and exists (select 1 from silver.pipeline_run where started_at > now() - make_interval(secs => v_min)) then
        return jsonb_build_object('status', 'debounced', 'new_data', v_new);
    end if;

    insert into silver.pipeline_run (trigger, new_data) values (p_trigger, v_new) returning run_id into v_run;

    -- 2. silver: parse / clean / load, one brand at a time so one failure does not block the rest
    for b in select brand_key from silver.brand_scope where is_enabled order by brand_key loop
        v_t := clock_timestamp();
        begin
            v_tmp := silver.refresh_brand(b.brand_key);
            v_steps := v_steps || jsonb_build_object('refresh_brand:' || b.brand_key, jsonb_build_object(
                'ok', true, 'seconds', round(extract(epoch from clock_timestamp() - v_t)::numeric, 2), 'stats', v_tmp));
        exception when others then
            v_failed := true;
            v_steps := v_steps || jsonb_build_object('refresh_brand:' || b.brand_key, jsonb_build_object('ok', false, 'error', sqlerrm));
        end;
    end loop;

    -- 3. market-wide category shelves
    v_t := clock_timestamp();
    begin
        perform silver.refresh_category_market();
        v_steps := v_steps || jsonb_build_object('refresh_category_market', jsonb_build_object(
            'ok', true, 'seconds', round(extract(epoch from clock_timestamp() - v_t)::numeric, 2)));
    exception when others then
        v_failed := true;
        v_steps := v_steps || jsonb_build_object('refresh_category_market', jsonb_build_object('ok', false, 'error', sqlerrm));
    end;

    -- 4. canonical map (SI ids)
    begin
        v_steps := v_steps || jsonb_build_object('map_new_products', jsonb_build_object('ok', true, 'result', silver.map_new_products()));
        v_steps := v_steps || jsonb_build_object('sync_canonical_attrs', jsonb_build_object('ok', true, 'updated', silver.sync_canonical_attrs()));
    exception when others then
        v_failed := true;
        v_steps := v_steps || jsonb_build_object('canonical_map', jsonb_build_object('ok', false, 'error', sqlerrm));
    end;

    -- 5. gold metrics (only on top of a clean silver load)
    if not v_failed then
        v_t := clock_timestamp();
        begin
            perform gold.refresh_all();
            v_steps := v_steps || jsonb_build_object('gold.refresh_all', jsonb_build_object(
                'ok', true, 'seconds', round(extract(epoch from clock_timestamp() - v_t)::numeric, 2)));
        exception when others then
            v_failed := true;
            v_steps := v_steps || jsonb_build_object('gold.refresh_all', jsonb_build_object('ok', false, 'error', sqlerrm));
        end;
    else
        v_steps := v_steps || jsonb_build_object('gold.refresh_all', jsonb_build_object('ok', false, 'skipped', 'silver step failed'));
    end if;

    -- watermarks advance only after a fully successful run (values read BEFORE the load,
    -- so rows that arrived mid-run trigger the next run)
    if not v_failed then
        update silver.pipeline_source ps
           set last_seen_id = (v_maxes ->> (ps.source_schema || '.' || ps.source_table))::bigint
         where v_maxes ? (ps.source_schema || '.' || ps.source_table);
    end if;

    update silver.pipeline_run
       set finished_at = clock_timestamp(), status = case when v_failed then 'partial' else 'success' end, steps = v_steps
     where run_id = v_run;

    return jsonb_build_object('status', case when v_failed then 'partial' else 'success' end,
                              'run_id', v_run, 'new_data', v_new, 'steps', v_steps);
end $$;
comment on function silver.run_pipeline(boolean, text) is 'Automatic bronze -> silver -> SI ids -> gold. p_force = run even with no new data. Called every minute by pg_cron.';

create or replace view silver.v_pipeline_status with (security_invoker = true) as
select
    (select started_at from silver.pipeline_run order by run_id desc limit 1)                  as last_run_at,
    (select status     from silver.pipeline_run order by run_id desc limit 1)                  as last_run_status,
    (select round(extract(epoch from finished_at - started_at)::numeric, 1)
       from silver.pipeline_run order by run_id desc limit 1)                                  as last_run_seconds,
    (select count(*) from silver.dim_product p
      where not exists (select 1 from silver.product_xref x where x.product_key = p.product_key)) as products_without_si_id,
    (select count(*) from silver.match_review_queue where status = 'pending')                 as reviews_pending,
    (select count(*) from silver.canonical_product where is_active)                           as si_ids,
    (select count(*) from silver.v_sidnl_product where platform_count > 1)                    as si_ids_on_multiple_platforms,
    (select count(*) from silver.pipeline_run where status = 'partial' and started_at > now() - interval '24 hours') as failed_runs_24h;
comment on view silver.v_pipeline_status is 'One-row health check of the automatic pipeline and the canonical map.';

-- ---------------------------------------------------------------------------
-- Schedules (pg_cron).  Names make these idempotent.
-- ---------------------------------------------------------------------------
create extension if not exists pg_cron;

select cron.schedule('sidnl-pipeline', '* * * * *', $cron$select silver.run_pipeline(false, 'cron')$cron$);
-- 00:05 IST daily: forced run so date-based gold tables roll over to the new day even if no data arrived
select cron.schedule('sidnl-pipeline-daily', '35 18 * * *', $cron$select silver.run_pipeline(true, 'cron-daily')$cron$);
