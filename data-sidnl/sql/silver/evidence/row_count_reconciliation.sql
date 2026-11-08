-- 1. Category-wise bronze vs silver (read-only)
with b as (
  select sn.platform, sn.l1_id, sn.l2_id, count(*) bronze_rows, count(*) filter (where sn.status='ok') bronze_ok
  from public.shelf_positions sp join public.shelf_snapshots sn on sn.id=sp.snapshot_id group by 1,2,3),
s as (select platform, l1_id, l2_id, count(*) silver_rows from silver.fact_shelf_position group by 1,2,3)
select coalesce(cs.l1_name||' > '||cs.l2_name,'(not in category_scope)') category, b.platform, b.bronze_rows, b.bronze_ok,
       coalesce(s.silver_rows,0) silver_rows, b.bronze_ok-coalesce(s.silver_rows,0) not_loaded, cs.created_at as scoped_at
from b left join s using (platform,l1_id,l2_id)
left join silver.category_scope cs on cs.platform=b.platform and cs.l1_id=b.l1_id and cs.l2_id=b.l2_id
order by silver_rows desc;
-- 2. Running total in the order categories were scoped (reproduces 508,760 and 570,136)
select cs.l1_name||' > '||cs.l2_name category, cs.created_at scoped_at,
       (select count(*) from silver.fact_shelf_position f where f.platform=cs.platform and f.l1_id=cs.l1_id and f.l2_id=cs.l2_id) silver_rows,
       sum((select count(*) from silver.fact_shelf_position f where f.platform=cs.platform and f.l1_id=cs.l1_id and f.l2_id=cs.l2_id)) over (order by cs.created_at, cs.l2_id) running_total
from silver.category_scope cs order by cs.created_at, cs.l2_id;
-- 3. Integrity
select (select count(*) from public.shelf_positions) bronze_total, (select count(*) from silver.fact_shelf_position) silver_total,
       (select count(*) from public.shelf_positions sp join public.shelf_snapshots sn on sn.id=sp.snapshot_id where sn.status<>'ok') bronze_not_ok,
       (select count(*) from silver.fact_shelf_position f where not exists (select 1 from public.shelf_positions sp where sp.id=f.source_record_id)) silver_orphans,
       (select count(*) from (select source_record_id from silver.fact_shelf_position group by 1 having count(*)>1) d) dup_source_ids,
       (select count(*) from public.shelf_positions sp join public.shelf_snapshots sn on sn.id=sp.snapshot_id join silver.category_scope cs on cs.platform=sn.platform and cs.l1_id=sn.l1_id and cs.l2_id=sn.l2_id and cs.is_enabled where sn.status='ok' and not exists (select 1 from silver.fact_shelf_position f where f.source_record_id=sp.id)) in_scope_missing;
-- 4. The unscoped category (why 210 rows are not loaded: fewer than silver.cfg('category_min_stores') = 10 stores)
select sn.platform, sn.l1_id, sn.l2_id, count(distinct sn.id) snapshots, count(distinct sn.store_id) stores, count(sp.id) rows_
from public.shelf_snapshots sn join public.shelf_positions sp on sp.snapshot_id=sn.id
where not exists (select 1 from silver.category_scope cs where cs.platform=sn.platform and cs.l1_id=sn.l1_id and cs.l2_id=sn.l2_id)
group by 1,2,3;
