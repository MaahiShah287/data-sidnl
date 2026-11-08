-- 042: storage threshold alerts + growth projection. ALERT ONLY: no deletion, retention or archival.
insert into silver.sidnl_config(key, value_num, description) values
 ('storage_plan_gb', 8, 'Included disk (GB) of the Supabase Pro plan - confirm in dashboard (Settings > Compute and Disk); adjust if disk is scaled up'),
 ('storage_warn_pct', 70, 'Warn when DB+WAL usage exceeds this % of storage_plan_gb'),
 ('storage_crit_pct', 85, 'Critical when DB+WAL usage exceeds this % of storage_plan_gb')
on conflict (key) do nothing;

create table if not exists silver.storage_alert_log(
  alert_id bigserial primary key, alerted_at timestamptz not null default now(),
  level text not null, used_bytes bigint, plan_bytes bigint, used_pct numeric, db_bytes bigint, wal_bytes bigint, message text);

create or replace function silver.storage_usage() returns table(db_bytes bigint, wal_bytes bigint, used_bytes bigint, plan_bytes bigint, used_pct numeric, level text)
language plpgsql set search_path to 'silver','public','pg_temp' as $f$
declare v_db bigint := pg_database_size(current_database()); v_wal bigint := 0; v_plan bigint;
        v_w numeric := coalesce(silver.cfg('storage_warn_pct'),70); v_c numeric := coalesce(silver.cfg('storage_crit_pct'),85);
begin
  begin select coalesce(sum(size),0) into v_wal from pg_ls_waldir(); exception when others then v_wal := 0; end;
  v_plan := (coalesce(silver.cfg('storage_plan_gb'),8) * 1024^3)::bigint;
  return query select v_db, v_wal, v_db+v_wal, v_plan, round(100.0*(v_db+v_wal)/v_plan,2),
     case when 100.0*(v_db+v_wal)/v_plan >= v_c then 'critical' when 100.0*(v_db+v_wal)/v_plan >= v_w then 'warning' else 'ok' end;
end $f$;

create or replace function silver.check_storage_alert() returns text
language plpgsql set search_path to 'silver','public','pg_temp' as $f$
declare u record; v_last text; v_last_at timestamptz;
begin
  select * into u from silver.storage_usage();
  select level, alerted_at into v_last, v_last_at from silver.storage_alert_log order by alert_id desc limit 1;
  -- log on level change, and re-log non-ok levels once per day
  if u.level is distinct from coalesce(v_last,'ok') or (u.level <> 'ok' and v_last_at < now() - interval '1 day') then
    insert into silver.storage_alert_log(level, used_bytes, plan_bytes, used_pct, db_bytes, wal_bytes, message)
    values (u.level, u.used_bytes, u.plan_bytes, u.used_pct, u.db_bytes, u.wal_bytes,
            format('storage %s: %s%% of %s GB plan (db %s MB + wal %s MB)', u.level, u.used_pct, round(u.plan_bytes/1024^3.0,1), u.db_bytes/1048576, u.wal_bytes/1048576));
    if u.level <> 'ok' then raise warning 'SIDNL storage % at % %%', u.level, u.used_pct; end if;
  end if;
  return u.level;
end $f$;

create or replace view silver.v_storage_projection as
with days as (select (((now() at time zone 'Asia/Kolkata')::date) - k) as dy from generate_series(0,13) k),
per as (select (sn.taken_at at time zone 'Asia/Kolkata')::date dy, count(*) n
          from public.shelf_snapshots sn join public.shelf_positions sp on sp.snapshot_id = sn.id
         where sn.taken_at >= now() - interval '15 days' group by 1),
rate as (select count(*) filter (where coalesce(p.n,0) > 0) active_days, coalesce(sum(p.n),0)/14.0 avg_rows_per_day, coalesce(max(p.n),0) peak_rows_day
           from days d left join per p on p.dy = d.dy),
cost as (select pg_total_relation_size('public.shelf_positions')::numeric / nullif((select count(*) from public.shelf_positions),0)
              + pg_total_relation_size('silver.fact_shelf_position')::numeric / nullif((select count(*) from silver.fact_shelf_position),0) as bytes_per_scraped_row)
select u.db_bytes, u.wal_bytes, u.used_bytes, u.plan_bytes, u.used_pct, u.level,
       r.active_days, r.avg_rows_per_day, r.peak_rows_day, round(c.bytes_per_scraped_row) bytes_per_scraped_row,
       round(r.avg_rows_per_day*c.bytes_per_scraped_row/1048576,1) growth_mb_per_day_avg,
       round(r.peak_rows_day*c.bytes_per_scraped_row/1048576,1)    growth_mb_per_day_peak,
       round((u.plan_bytes-u.used_bytes)/nullif(r.avg_rows_per_day*c.bytes_per_scraped_row,0)) days_to_full_at_avg,
       round((u.plan_bytes-u.used_bytes)/nullif(r.peak_rows_day*c.bytes_per_scraped_row,0))    days_to_full_at_peak
from silver.storage_usage() u cross join rate r cross join cost c;

-- evaluate on every record_storage_snapshot() call (already invoked from run_tick); snapshot logic unchanged
create or replace function silver.record_storage_snapshot() returns integer
language plpgsql set search_path to 'silver','public','pg_temp' as $f$
declare v_d date := (now() at time zone 'Asia/Kolkata')::date; v_n int := 0;
begin
  begin perform silver.check_storage_alert(); exception when others then raise warning 'check_storage_alert failed: %', sqlerrm; end;
  if exists (select 1 from silver.storage_snapshot where snapshot_date = v_d) then return 0; end if;
  insert into silver.storage_snapshot (snapshot_date, relation, total_bytes, table_bytes, index_bytes, live_rows, dead_rows, db_bytes)
  select v_d, n.nspname || '.' || c.relname, pg_total_relation_size(c.oid), pg_relation_size(c.oid), pg_indexes_size(c.oid),
         s.n_live_tup, s.n_dead_tup, pg_database_size(current_database())
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    left join pg_stat_all_tables s on s.relid = c.oid
   where c.relkind = 'r' and n.nspname in ('silver','public') and pg_total_relation_size(c.oid) > 1024*1024
  on conflict do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $f$;
