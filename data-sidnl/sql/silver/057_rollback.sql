-- Rollback for silver_057_seen_dates_and_stale_review.
update silver.dim_product d set first_seen_at = b.first_seen_at
  from ops.backup_silver_057 b where b.product_key = d.product_key;
update silver.match_review_queue set status = 'pending', decided_by = null, decided_at = null
 where status = 'rejected' and decided_by like 'system:silver_057%';
drop table ops.backup_silver_057;
