-- silver_057_seen_dates_and_stale_review
-- docs/silver/CANONICAL_MAPPING_AUDIT_2026-11-10.md D2 + D5.
-- D2: 63 products (all non-client brands loaded by the category loader, e.g. McCain 18, ITC Master Chef 9) had a
--     first_seen_at later than their own earliest fact (e.g. 2026-11-07 vs 2026-10-29). The loader already uses
--     least(); this is a one-time historical leftover. Set first_seen_at to the earliest observed_at of the product's
--     own silver facts (which match bronze row-for-row). Old values are kept in ops.backup_silver_057 for rollback.
-- D5: review 2 (product 1108) was still 'pending' although the product already has its own SI id. Fuzzy names are
--     never merged automatically, so it is closed as rejected through the existing silver.reject_match().

create table ops.backup_silver_057 as
select d.product_key, d.first_seen_at
from silver.dim_product d
join (select product_key, min(observed_at) mn
        from (select product_key, observed_at from silver.fact_shelf_position where product_key is not null
              union all
              select product_key, observed_at from silver.fact_product_reading where product_key is not null) u
       group by 1) f using (product_key)
where d.first_seen_at > f.mn;
alter table ops.backup_silver_057 enable row level security;
comment on table ops.backup_silver_057 is 'Rollback data for silver_057 (dim_product.first_seen_at before the correction). Safe to drop once silver_057 is accepted.';

update silver.dim_product d
   set first_seen_at = f.mn
  from (select product_key, min(observed_at) mn
          from (select product_key, observed_at from silver.fact_shelf_position where product_key is not null
                union all
                select product_key, observed_at from silver.fact_product_reading where product_key is not null) u
         group by 1) f
 where f.product_key = d.product_key
   and d.product_key in (select product_key from ops.backup_silver_057);

select silver.reject_match(r.review_id,
         'system:silver_057 stale review - product already has its own SI id; fuzzy names are never merged automatically')
  from silver.match_review_queue r
  join silver.product_xref x using (product_key)
 where r.status = 'pending' and x.match_status <> 'PENDING_REVIEW';
