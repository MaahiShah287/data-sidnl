-- silver_063_dead_letter  (Gap 3 of docs/fallbacks-design.md)
-- Before: silver.refresh_category_scope loads bronze shelf rows in id chunks; ONE bad row raised for the whole category
-- scope, so the scope failed, its watermark stopped and nothing new loaded for it (the 551 failed jobs of 2026-11-09).
-- After:
--   * the chunk body is unchanged but lives in silver.load_category_chunk() and skips bronze rows that are 'open' in
--     ops.dead_letter (the only change to what it loads)
--   * silver.load_category_range() runs a chunk; on a PERMANENT error (silver.classify_error) it splits the id range in
--     half and retries each half, down to single bronze rows. A single row that still fails is written to ops.dead_letter
--     with the error, and every other row loads. Transient errors are re-raised unchanged (scope retried with backoff
--     as before). If more than sidnl_config.dead_letter_max_per_chunk rows would be dead-lettered from one chunk, the
--     error is not row-specific: it is re-raised (SQLSTATE 22S01) and the scope fails exactly as before, so a global
--     problem never parks rows silently.
--   * silver.retry_dead_letters() (cron sidnl-dead-letter, every 15 min) reloads open rows one by one with backoff;
--     a row that loads becomes 'resolved'. silver.ignore_dead_letter() closes a row by hand with a reason. Rows are never deleted.
--   * silver.reconcile_coverage() (cron sidnl-reconcile-coverage, daily) proves no bronze row is skipped silently: every
--     shelf row of an enabled scope up to its watermark is either in silver.fact_shelf_position or in ops.dead_letter.
-- The brand loader (refresh_brand, client brands only) keeps its existing per-brand isolation and retry.

insert into ops.function_backup (fn, tag, definition)
select 'silver.refresh_category_scope(text,text,text,boolean)', 'pre_silver_063',
       pg_get_functiondef('silver.refresh_category_scope(text,text,text,boolean)'::regprocedure);

insert into silver.sidnl_config (key, value_num, description) values
  ('dead_letter_max_per_chunk', 100, 'More rows than this failing in one category chunk means the error is not row-specific: the scope fails instead of dead-lettering'),
  ('dead_letter_retry_minutes', 60, 'Minimum minutes between automatic retries of a dead-lettered bronze row (doubles per attempt, max 24 h)'),
  ('dead_letter_max_retries', 24, 'After this many failed retries a dead-lettered row stays open but is no longer retried automatically (alert raised)')
on conflict (key) do nothing;

create table ops.dead_letter (
    dl_id               bigint generated always as identity primary key,
    source_table        text not null,
    bronze_id           bigint not null,
    platform            text,
    l1_id               text,
    l2_id               text,
    platform_product_id text,
    reason              text,
    sqlstate            text,
    first_seen_at       timestamptz not null default now(),
    last_seen_at        timestamptz not null default now(),
    retry_count         integer not null default 0,
    last_tried_at       timestamptz,
    next_retry_at       timestamptz not null default now(),
    status              text not null default 'open' check (status in ('open', 'retrying', 'resolved', 'ignored')),
    resolved_at         timestamptz,
    resolved_by         text,
    note                text,
    unique (source_table, bronze_id)
);
create index ix_dead_letter_open on ops.dead_letter (bronze_id) where status = 'open';
alter table ops.dead_letter enable row level security;
comment on table ops.dead_letter is
  'silver_063: bronze rows that failed to load with a permanent error. open = excluded from loads and retried; resolved = loaded later; ignored = closed by hand.';

create view ops.v_dead_letter_summary with (security_invoker = true) as
select source_table, platform, l1_id, l2_id, status, count(*) as rows, min(first_seen_at) as oldest,
       max(retry_count) as max_retries, (array_agg(reason order by last_seen_at desc))[1] as latest_reason
  from ops.dead_letter group by 1, 2, 3, 4, 5;

-- chunk body of refresh_category_scope, unchanged except the dead-letter exclusion in src
create or replace function silver.load_category_chunk(p_platform text, p_l1 text, p_l2 text, p_lo bigint, p_hi bigint, p_run bigint)
 returns jsonb
 language plpgsql
 set search_path to 'silver', 'ops', 'public', 'pg_temp'
as $function$
declare v_ins int; v_upd int; v_new_stores int; v_p jsonb;
begin
        with ins as (
            insert into silver.dim_store (platform, store_external_id, source_store_id, store_name, city_slug,
                                          latitude, longitude, first_seen_at, last_seen_at)
            select s.platform, s.external_id, s.id, s.name, s.city_slug, s.lat, s.lon, s.first_seen_at, s.last_seen_at
            from public.stores s
            where s.id in (
                    select distinct coalesce(sp.store_id, sn.store_id)
                    from public.shelf_positions sp
                    join public.shelf_snapshots sn on sn.id = sp.snapshot_id
                    where sp.id > p_lo and sp.id <= p_hi and sn.status = 'ok'
                      and sn.platform = p_platform and sn.l1_id = p_l1 and sn.l2_id = p_l2)
              and s.platform in (select platform from silver.dim_platform)
            on conflict (source_store_id) do nothing
            returning 1)
        select count(*) into v_new_stores from ins;

        with src as materialized (
            select sp.id, sp.snapshot_id, sn.platform, sn.l1_id, sn.l2_id, coalesce(sp.store_id, sn.store_id) as src_store,
                   sn.taken_at, sp."position" as pos, sp.organic_position as opos, sp.is_ad, sp.ad_type, pp.brand,
                   sp.external_id, pp.name, pp.pack, sp.state, sp.inventory, sp.inventory_capped,
                   sp.price::numeric as price, sp.mrp::numeric as mrp,
                   sn.cards_seen, sn.total_items, sn.complete
            from public.shelf_positions sp
            join public.shelf_snapshots sn on sn.id = sp.snapshot_id
            left join public.platform_products pp on pp.platform = sn.platform and pp.external_id = sp.external_id
            join silver.dim_platform dpl on dpl.platform = sn.platform and not dpl.is_test
            where sp.id > p_lo and sp.id <= p_hi and sn.status = 'ok'
              and sn.platform = p_platform and sn.l1_id = p_l1 and sn.l2_id = p_l2
              and not exists (select 1 from ops.dead_letter dl
                               where dl.status = 'open' and dl.source_table = 'public.shelf_positions' and dl.bronze_id = sp.id)
        ), bm as materialized (
            select x.b as raw_brand,
                   (select sb.brand_key from silver.brand_scope sb
                     where sb.is_enabled and silver.brand_matches(sb.brand_key, x.b)
                     order by sb.brand_key limit 1) as client_key
            from (select distinct brand as b from src where brand is not null) x
            offset 0
        ), ins as (
            insert into silver.fact_shelf_position as t (
                source_record_id, snapshot_id, platform, l1_id, l2_id, store_key, city_slug, observed_at, shelf_position,
                organic_position, is_ad, ad_type, brand_raw, brand_key, is_client_brand, platform_product_id, product_name,
                pack_raw, stock_status, inventory_units, inventory_is_capped, selling_price, mrp,
                shelf_cards_seen, shelf_total_items, shelf_complete, dq_status, dq_flags, etl_run_id)
            select s.id, s.snapshot_id, s.platform, s.l1_id, s.l2_id, ds.store_key, ds.city_slug, s.taken_at, s.pos, s.opos,
                   s.is_ad, s.ad_type, s.brand,
                   coalesce(bm.client_key, case when s.brand is null then null else nullif(silver.norm_key(s.brand), '') end, '(unknown)'),
                   bm.client_key is not null,
                   s.external_id, s.name, s.pack,
                   q.status, s.inventory, coalesce(s.inventory_capped, false), round(s.price, 2), round(s.mrp, 2),
                   s.cards_seen, s.total_items, s.complete, silver.dq_status(q.flags), q.flags, p_run
            from src s
            left join bm on bm.raw_brand = s.brand
            left join silver.dim_store ds on ds.source_store_id = s.src_store
            cross join lateral (
                select silver.map_stock_status(s.state) as status,
                       silver.reading_dq(true, ds.store_key is not null, s.taken_at, silver.map_stock_status(s.state),
                                         s.inventory, round(s.price, 2), round(s.mrp, 2)) as flags) q
            on conflict (source_record_id) do update set
                snapshot_id = excluded.snapshot_id, store_key = excluded.store_key, city_slug = excluded.city_slug,
                observed_at = excluded.observed_at, shelf_position = excluded.shelf_position,
                organic_position = excluded.organic_position, is_ad = excluded.is_ad, ad_type = excluded.ad_type,
                brand_raw = excluded.brand_raw, brand_key = excluded.brand_key, is_client_brand = excluded.is_client_brand,
                platform_product_id = excluded.platform_product_id, product_name = excluded.product_name,
                pack_raw = excluded.pack_raw, stock_status = excluded.stock_status, inventory_units = excluded.inventory_units,
                inventory_is_capped = excluded.inventory_is_capped, selling_price = excluded.selling_price, mrp = excluded.mrp,
                shelf_cards_seen = excluded.shelf_cards_seen, shelf_total_items = excluded.shelf_total_items,
                shelf_complete = excluded.shelf_complete, dq_status = excluded.dq_status, dq_flags = excluded.dq_flags,
                loaded_at = now(), etl_run_id = excluded.etl_run_id
            where (t.snapshot_id, t.store_key, t.city_slug, t.observed_at, t.shelf_position, t.organic_position, t.is_ad, t.ad_type,
                   t.brand_raw, t.brand_key, t.is_client_brand, t.platform_product_id, t.product_name, t.pack_raw, t.stock_status,
                   t.inventory_units, t.inventory_is_capped, t.selling_price, t.mrp, t.shelf_cards_seen, t.shelf_total_items,
                   t.shelf_complete, t.dq_status, t.dq_flags)
                  is distinct from
                  (excluded.snapshot_id, excluded.store_key, excluded.city_slug, excluded.observed_at, excluded.shelf_position,
                   excluded.organic_position, excluded.is_ad, excluded.ad_type, excluded.brand_raw, excluded.brand_key,
                   excluded.is_client_brand, excluded.platform_product_id, excluded.product_name, excluded.pack_raw,
                   excluded.stock_status, excluded.inventory_units, excluded.inventory_is_capped, excluded.selling_price,
                   excluded.mrp, excluded.shelf_cards_seen, excluded.shelf_total_items, excluded.shelf_complete,
                   excluded.dq_status, excluded.dq_flags)
            returning (xmax = 0) as inserted)
        select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;

        v_p := silver.refresh_category_products(p_run, p_lo, p_hi);

        return jsonb_build_object('stores', v_new_stores, 'ins', v_ins, 'upd', v_upd,
                                  'pb', (v_p ->> 'brands')::int, 'pi', (v_p ->> 'ins')::int,
                                  'pu', (v_p ->> 'upd')::int, 'pl', (v_p ->> 'linked')::int, 'dead_lettered', 0);
end $function$;

-- run a chunk; on a permanent error bisect down to the failing bronze rows and dead-letter only those
create or replace function silver.load_category_range(p_platform text, p_l1 text, p_l2 text, p_lo bigint, p_hi bigint, p_run bigint)
 returns jsonb
 language plpgsql
 set search_path to 'silver', 'ops', 'public', 'pg_temp'
as $function$
declare
    v_state text; v_msg text; v_mid bigint; a jsonb; b jsonb; v_n int;
    v_cap int := coalesce(silver.cfg('dead_letter_max_per_chunk'), 100)::int;
begin
    begin
        return silver.load_category_chunk(p_platform, p_l1, p_l2, p_lo, p_hi, p_run);
    exception when others then
        v_state := sqlstate; v_msg := sqlerrm;
    end;
    if v_state = '22S01' or silver.classify_error(v_state) <> 'permanent' then
        raise exception using errcode = v_state, message = v_msg;
    end if;

    if p_hi - p_lo <= 1 then
        if not exists (select 1 from public.shelf_positions sp join public.shelf_snapshots sn on sn.id = sp.snapshot_id
                        where sp.id = p_hi and sn.status = 'ok'
                          and sn.platform = p_platform and sn.l1_id = p_l1 and sn.l2_id = p_l2) then
            raise exception using errcode = v_state, message = v_msg;   -- not caused by a row of this scope
        end if;
        v_n := coalesce(nullif(current_setting('sidnl.dl_count', true), ''), '0')::int + 1;
        if v_n > v_cap then
            raise exception using errcode = '22S01',
                  message = format('dead-letter cap (%s rows in one chunk) exceeded, error is not row-specific: %s', v_cap, v_msg);
        end if;
        perform set_config('sidnl.dl_count', v_n::text, true);
        insert into ops.dead_letter (source_table, bronze_id, platform, l1_id, l2_id, platform_product_id, reason, sqlstate,
                                     next_retry_at)
        select 'public.shelf_positions', sp.id, sn.platform, sn.l1_id, sn.l2_id, sp.external_id, left(v_msg, 1000), v_state,
               now() + make_interval(mins => coalesce(silver.cfg('dead_letter_retry_minutes'), 60)::int)
          from public.shelf_positions sp join public.shelf_snapshots sn on sn.id = sp.snapshot_id
         where sp.id = p_hi
        on conflict (source_table, bronze_id) do update set
            reason = excluded.reason, sqlstate = excluded.sqlstate, last_seen_at = now(),
            status = case when ops.dead_letter.status in ('resolved', 'retrying') then 'open' else ops.dead_letter.status end;
        return jsonb_build_object('stores', 0, 'ins', 0, 'upd', 0, 'pb', 0, 'pi', 0, 'pu', 0, 'pl', 0, 'dead_lettered', 1);
    end if;

    v_mid := p_lo + (p_hi - p_lo) / 2;
    a := silver.load_category_range(p_platform, p_l1, p_l2, p_lo, v_mid, p_run);
    b := silver.load_category_range(p_platform, p_l1, p_l2, v_mid, p_hi, p_run);
    return jsonb_build_object(
        'stores', coalesce((a->>'stores')::int, 0) + coalesce((b->>'stores')::int, 0),
        'ins',    coalesce((a->>'ins')::int, 0)    + coalesce((b->>'ins')::int, 0),
        'upd',    coalesce((a->>'upd')::int, 0)    + coalesce((b->>'upd')::int, 0),
        'pb',     coalesce((a->>'pb')::int, 0)     + coalesce((b->>'pb')::int, 0),
        'pi',     coalesce((a->>'pi')::int, 0)     + coalesce((b->>'pi')::int, 0),
        'pu',     coalesce((a->>'pu')::int, 0)     + coalesce((b->>'pu')::int, 0),
        'pl',     coalesce((a->>'pl')::int, 0)     + coalesce((b->>'pl')::int, 0),
        'dead_lettered', coalesce((a->>'dead_lettered')::int, 0) + coalesce((b->>'dead_lettered')::int, 0));
end $function$;

create or replace function silver.refresh_category_scope(p_platform text, p_l1 text, p_l2 text, p_full boolean default false)
 returns jsonb
 language plpgsql
 set search_path to 'silver', 'ops', 'public', 'pg_temp'
as $function$
declare
    v_run bigint; v_c jsonb;
    v_tot_ins int := 0; v_tot_upd int := 0; v_tot_stores int := 0; v_dl int := 0;
    v_pb int := 0; v_pi int := 0; v_pu int := 0; v_pl int := 0; v_stats jsonb;
    v_lb   bigint := coalesce(silver.cfg('incremental_lookback_rows'), 5000)::bigint;
    v_step bigint := coalesce(silver.cfg('category_chunk_rows'), 50000)::bigint;
    v_wm bigint; v_start bigint; v_max bigint; v_lo bigint; v_hi bigint; v_loaded boolean;
begin
    select cs.last_loaded_id into v_wm from silver.category_scope cs
     where cs.platform = p_platform and cs.l1_id = p_l1 and cs.l2_id = p_l2 and cs.is_enabled;
    if not found then return jsonb_build_object('skipped', 'scope not enabled', 'max_id', null); end if;
    v_loaded := exists (select 1 from silver.fact_shelf_position f where f.platform = p_platform and f.l1_id = p_l1 and f.l2_id = p_l2);
    select coalesce(max(id), 0) into v_max from public.shelf_positions;
    if not p_full and v_loaded and v_wm is not null and v_max <= v_wm then
        return jsonb_build_object('skipped', 'no new bronze rows', 'max_id', v_wm,
                                  'fact_shelf_position', jsonb_build_object('inserted', 0, 'updated', 0));
    end if;
    v_start := case when p_full or v_wm is null or not v_loaded then 0 else greatest(v_wm - v_lb, 0) end;

    insert into ops.etl_run (brand_key) values ('(category:' || p_platform || '/' || p_l1 || '/' || p_l2 || ')') returning run_id into v_run;

    v_lo := v_start;
    while v_lo < v_max loop
        v_hi := v_lo + v_step;
        perform set_config('sidnl.dl_count', '0', true);
        v_c := silver.load_category_range(p_platform, p_l1, p_l2, v_lo, v_hi, v_run);
        v_tot_stores := v_tot_stores + coalesce((v_c ->> 'stores')::int, 0);
        v_tot_ins := v_tot_ins + coalesce((v_c ->> 'ins')::int, 0);
        v_tot_upd := v_tot_upd + coalesce((v_c ->> 'upd')::int, 0);
        v_pb := v_pb + coalesce((v_c ->> 'pb')::int, 0); v_pi := v_pi + coalesce((v_c ->> 'pi')::int, 0);
        v_pu := v_pu + coalesce((v_c ->> 'pu')::int, 0); v_pl := v_pl + coalesce((v_c ->> 'pl')::int, 0);
        v_dl := v_dl + coalesce((v_c ->> 'dead_lettered')::int, 0);
        v_lo := v_hi;
    end loop;

    v_stats := jsonb_build_object(
        'mode', case when p_full then 'full' when not v_loaded then 'new_category' else 'incremental' end,
        'max_id', v_max, 'dim_store_added', v_tot_stores,
        'fact_shelf_position', jsonb_build_object('inserted', v_tot_ins, 'updated', v_tot_upd),
        'dim_brand_added', v_pb, 'dim_product', jsonb_build_object('inserted', v_pi, 'updated', v_pu),
        'shelf_rows_linked', v_pl, 'dead_lettered', v_dl, 'run_id', v_run);
    update ops.etl_run set finished_at = now(), status = 'success', stats = v_stats where run_id = v_run;
    return v_stats;
end $function$;

create or replace function silver.retry_dead_letters(p_force boolean default false)
 returns jsonb
 language plpgsql
 set search_path to 'silver', 'ops', 'public', 'pg_temp'
as $function$
declare
    r record; v_run bigint; v_ok int := 0; v_fail int := 0; v_st text; v_er text;
    v_max int := coalesce(silver.cfg('dead_letter_max_retries'), 24)::int;
    v_min int := coalesce(silver.cfg('dead_letter_retry_minutes'), 60)::int;
begin
    if not exists (select 1 from ops.dead_letter where status = 'open') then
        return jsonb_build_object('status', 'nothing to do');
    end if;
    if not pg_try_advisory_xact_lock(727100) then
        return jsonb_build_object('status', 'skipped', 'reason', 'pipeline run in progress');
    end if;
    insert into ops.etl_run (brand_key) values ('(dead-letter retry)') returning run_id into v_run;

    for r in select * from ops.dead_letter
              where status = 'open' and source_table = 'public.shelf_positions'
                and (p_force or (next_retry_at <= now() and retry_count < v_max))
              order by dl_id limit 500
    loop
        begin
            update ops.dead_letter set status = 'retrying' where dl_id = r.dl_id;
            perform silver.load_category_chunk(r.platform, r.l1_id, r.l2_id, r.bronze_id - 1, r.bronze_id, v_run);
            if not exists (select 1 from silver.fact_shelf_position where source_record_id = r.bronze_id) then
                raise exception using errcode = '22S02', message = 'row not loaded (scope disabled or snapshot not ok)';
            end if;
            update ops.dead_letter set status = 'resolved', resolved_at = now(), resolved_by = 'auto-retry', last_tried_at = now()
             where dl_id = r.dl_id;
            v_ok := v_ok + 1;
        exception when others then
            v_st := sqlstate; v_er := sqlerrm;
            update ops.dead_letter
               set retry_count = retry_count + 1, last_tried_at = now(), reason = left(v_er, 1000), sqlstate = v_st,
                   next_retry_at = now() + least(make_interval(mins => v_min * power(2, least(retry_count, 10))::int), interval '24 hours')
             where dl_id = r.dl_id;
            v_fail := v_fail + 1;
        end;
    end loop;

    insert into ops.cron_alert_log (jobname, level, consecutive_failures, last_failure_message)
    select 'dead-letter:' || coalesce(platform, '?') || '/' || coalesce(l1_id, '?') || '/' || coalesce(l2_id, '?'), 'alert', max(retry_count),
           format('%s bronze rows stopped auto-retrying after %s attempts; latest error: %s', count(*), v_max,
                  (array_agg(reason order by last_tried_at desc))[1])
      from ops.dead_letter
     where status = 'open' and retry_count = v_max and last_tried_at > now() - interval '30 minutes'
     group by platform, l1_id, l2_id;

    update ops.etl_run set finished_at = now(), status = 'success',
           stats = jsonb_build_object('resolved', v_ok, 'still_failing', v_fail) where run_id = v_run;
    if v_ok > 0 then
        update ops.pipeline_run set gold_status = 'pending'
         where run_id = (select max(run_id) from ops.pipeline_run where status = 'success') and gold_status is distinct from 'pending';
    end if;
    return jsonb_build_object('status', 'ok', 'resolved', v_ok, 'still_failing', v_fail);
end $function$;

create or replace function silver.ignore_dead_letter(p_dl_id bigint, p_by text, p_reason text)
 returns text
 language plpgsql
 set search_path to 'silver', 'ops', 'public', 'pg_temp'
as $function$
begin
    if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required'; end if;
    update ops.dead_letter set status = 'ignored', resolved_at = now(), resolved_by = p_by, note = p_reason
     where dl_id = p_dl_id and status = 'open';
    if not found then raise exception 'dead letter % is not open', p_dl_id; end if;
    return 'ignored';
end $function$;

create or replace function silver.reconcile_coverage()
 returns jsonb
 language plpgsql
 set search_path to 'silver', 'ops', 'public', 'pg_temp'
as $function$
declare v_n bigint; v_bad bigint; v_now timestamptz := now();
begin
    select count(*), count(*) filter (where f.source_record_id is null and dl.bronze_id is null)
      into v_n, v_bad
      from public.shelf_positions sp
      join public.shelf_snapshots sn on sn.id = sp.snapshot_id and sn.status = 'ok'
      join silver.category_scope cs on cs.platform = sn.platform and cs.l1_id = sn.l1_id and cs.l2_id = sn.l2_id
                                   and cs.is_enabled and sp.id <= cs.last_loaded_id
      join silver.dim_platform pl on pl.platform = sn.platform and not pl.is_test
      left join silver.fact_shelf_position f on f.source_record_id = sp.id
      left join ops.dead_letter dl on dl.source_table = 'public.shelf_positions' and dl.bronze_id = sp.id and dl.status in ('open', 'ignored');
    insert into ops.reconciliation_log (run_at, check_name, status, rows_checked, mismatches, detail)
    values (v_now, 'shelf_rows_accounted', case when v_bad = 0 then 'ok' else 'mismatch' end, v_n, v_bad,
            jsonb_build_object('open_dead_letters', (select count(*) from ops.dead_letter where status = 'open'),
                               'ignored_dead_letters', (select count(*) from ops.dead_letter where status = 'ignored')));
    if v_bad > 0 then
        insert into ops.cron_alert_log (jobname, level, consecutive_failures, last_failure_message)
        values ('sidnl-reconcile:coverage', 'alert', 1, format('%s bronze shelf rows below their scope watermark are neither in silver nor dead-lettered', v_bad));
    end if;
    return jsonb_build_object('rows_checked', v_n, 'unaccounted', v_bad);
end $function$;

select cron.schedule('sidnl-dead-letter', '*/15 * * * *',
                     $cmd$set statement_timeout = '300s'; select silver.retry_dead_letters()$cmd$);
select cron.schedule('sidnl-reconcile-coverage', '40 19 * * *',
                     $cmd$set statement_timeout = '600s'; select silver.reconcile_coverage()$cmd$);
