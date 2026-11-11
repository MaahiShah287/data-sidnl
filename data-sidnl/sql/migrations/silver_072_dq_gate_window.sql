-- silver_072_dq_gate_window
-- Performance: silver.dq_checks() (the quality gate, every pipeline run) grouped all of fact_shelf_position
-- (~1.8 M rows, the largest table) on every run. Now:
--   * negative-price / price>MRP / brand checks read only the processing window (source_record_id > watermark -
--     incremental_lookback_rows), through the existing unique index on source_record_id;
--   * the blocking product / store link checks still cover every row, through two new small partial indexes;
--   * knob silver.sidnl_config.dq_gate_window (1 = window, 0 = previous full scan) is the fallback.
-- Semantics: `total` and the dq_reject_block_pct base are now "rows in this run's window" instead of "all rows ever";
-- the brand check is enforced anyway by the deferred FK fact_shelf_position_brand_key_fkey.
-- Index build reads the table once and blocks writes to it for its duration (seconds); apply between pipeline runs.

create index if not exists ix_fsp_unlinked on silver.fact_shelf_position (platform, l1_id, l2_id)
    where product_key is null and platform_product_id is not null;
create index if not exists ix_fsp_no_store on silver.fact_shelf_position (platform, l1_id, l2_id)
    where store_key is null;

insert into silver.sidnl_config (key, value_num, description)
values ('dq_gate_window', 1, '1 = quality gate price/brand checks read the processing window only (silver_072); 0 = full table')
on conflict (key) do nothing;

CREATE OR REPLACE FUNCTION silver.dq_checks(p_shelf_max bigint DEFAULT NULL::bigint)
 RETURNS TABLE(check_name text, severity text, scope text, violations bigint, total bigint, ok boolean, blocks boolean, detail text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'silver', 'ops', 'public', 'pg_temp'
AS $function$
with pct as (select coalesce(silver.cfg('dq_reject_block_pct'), 5) as p),
lb  as (select coalesce(greatest(ps.last_seen_id - coalesce(silver.cfg('incremental_lookback_rows'), 5000)::bigint, 0), 0) as lo
          from silver.pipeline_source ps where ps.source_schema = 'public' and ps.source_table = 'shelf_positions'),
-- silver_072: price flags and brand links are checked over the processing window (the rows this run can have
-- written; dq_gate_window = 0 restores the full-table scan). Product / store links stay checked over ALL rows, read
-- through the partial indexes ix_fsp_unlinked / ix_fsp_no_store, so an old broken row still blocks its scope.
lo as (select case when coalesce(silver.cfg('dq_gate_window'), 1) = 1 then coalesce((select lb.lo from lb), 0)
                   else -1 end as lo),
tw as (
    select f.platform, f.l1_id, f.l2_id, count(*) as total,
           count(*) filter (where 'negative_price' = any (f.dq_flags))                       as neg,
           count(*) filter (where 'sp_gt_mrp'      = any (f.dq_flags))                       as sp,
           count(*) filter (where b.brand_key is null)                                       as nobrand
      from silver.fact_shelf_position f
      left join silver.dim_brand b on b.brand_key = f.brand_key
     where f.source_record_id > (select lo.lo from lo)
     group by 1, 2, 3),
ri as (
    select z.platform, z.l1_id, z.l2_id, sum(z.unlinked) as unlinked, sum(z.nostore) as nostore
      from (select f.platform, f.l1_id, f.l2_id, count(*) as unlinked, 0::bigint as nostore
              from silver.fact_shelf_position f
             where f.product_key is null and f.platform_product_id is not null
             group by 1, 2, 3
            union all
            select f.platform, f.l1_id, f.l2_id, 0::bigint, count(*)
              from silver.fact_shelf_position f
             where f.store_key is null
             group by 1, 2, 3) z
     group by 1, 2, 3),
t as (
    select platform, l1_id, l2_id, coalesce(tw.total, 0) as total, coalesce(tw.neg, 0) as neg, coalesce(tw.sp, 0) as sp,
           coalesce(ri.unlinked, 0) as unlinked, coalesce(ri.nostore, 0) as nostore, coalesce(tw.nobrand, 0) as nobrand
      from tw full join ri using (platform, l1_id, l2_id)),
m as (
    select sn.platform, sn.l1_id, sn.l2_id, count(*) as missing
      from public.shelf_positions sp
      join public.shelf_snapshots sn on sn.id = sp.snapshot_id
      join silver.category_scope cs on cs.platform = sn.platform and cs.l1_id = sn.l1_id
                                   and cs.l2_id = sn.l2_id and cs.is_enabled
      join silver.dim_platform dpl on dpl.platform = sn.platform and not dpl.is_test
      cross join lb
     where sn.status = 'ok' and sp.id > lb.lo
       and sp.id <= coalesce(p_shelf_max, (select max(id) from public.shelf_positions))
       and not exists (select 1 from silver.fact_shelf_position f where f.source_record_id = sp.id)
     group by 1, 2, 3),
per_scope as (
    select c.n, c.sev, t.platform || '/' || t.l1_id || '/' || t.l2_id as scope, c.v, t.total, coalesce(c.blk, false) as blk, c.d
      from t cross join pct
      cross join lateral (values
        ('shelf_negative_selling_price', 'rejected', t.neg,
            t.neg * 100.0 / nullif(t.total, 0) > pct.p,
            'rows rejected from valid analytical output (dq_status=invalid); scope blocked only above dq_reject_block_pct'),
        ('shelf_selling_price_above_mrp', 'warning', t.sp, false,
            'rows flagged suspect and excluded from price/discount metrics; never blocks'),
        ('shelf_row_without_product', 'blocking', t.unlinked, t.unlinked > 0,
            'referential integrity: shelf row has a platform_product_id but no dim_product link'),
        ('shelf_row_without_store', 'blocking', t.nostore, t.nostore > 0,
            'referential integrity: shelf row has no dim_store'),
        ('shelf_row_brand_not_in_dim_brand', 'blocking', t.nobrand, t.nobrand > 0,
            'referential integrity: brand_key missing in dim_brand')
      ) c (n, sev, v, blk, d)
    union all
    select 'shelf_bronze_rows_not_in_silver', 'blocking', m.platform || '/' || m.l1_id || '/' || m.l2_id,
           m.missing, t.total, m.missing > 0,
           'unprocessed bronze rows inside the processing window - watermark must not advance'
      from m left join t on t.platform = m.platform and t.l1_id = m.l1_id and t.l2_id = m.l2_id)
select n, sev, scope, v, total, false, blk, d from per_scope where v > 0
union all
select n, sev, 'all', coalesce(sum(v), 0), coalesce(sum(total), 0), coalesce(sum(v), 0) = 0, coalesce(bool_or(blk), false), min(d)
  from per_scope group by n, sev
union all
select 'dim_store_without_city_or_coords', 'accepted', 'dim_store',
       count(*) filter (where city_slug is null or latitude is null or longitude is null), count(*), true, false,
       'optional descriptive NULLs: kept NULL, not derivable from source'
  from silver.dim_store
union all
select 'dim_product_without_category', 'accepted', 'dim_product',
       count(*) filter (where category_key is null), count(*), true, false,
       'optional descriptive NULLs: kept NULL, not derivable from source'
  from silver.dim_product
union all
select 'canonical_empty_name_clean', 'accepted', 'canonical_product',
       count(*) filter (where coalesce(name_clean, '') = ''), count(*), true, false,
       'approved: unchanged, SI id and raw name preserved'
  from silver.canonical_product where is_active
union all
select 'canonical:' || q.check_name, 'blocking', 'canonical',
       case when q.ok then 0 else 1 end, 1, q.ok, not q.ok, q.detail
  from silver.quality_checks() q
$function$
;
