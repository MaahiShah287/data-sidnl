-- silver_050_views_security_invoker
-- Audit finding 1 (docs/silver/SILVER_VIEW_AUDIT.md section 7): these 10 views ran with the owner's
-- rights and so bypassed the RLS enabled on every silver table. Owner callers (cron,
-- gold.refresh_listing, sidnl_find, CLI) see the same rows: all objects are owned by postgres,
-- no FORCE RLS, no other grants. Only reloptions change. Rollback: drafts/050_rollback.sql.
alter view silver.v_reading          set (security_invoker = true);
alter view silver.v_reading_current  set (security_invoker = true);
alter view silver.v_data_freshness   set (security_invoker = true);
alter view silver.v_sku_listing      set (security_invoker = true);
alter view silver.v_wide             set (security_invoker = true);
alter view silver.blinkit            set (security_invoker = true);
alter view silver.zepto              set (security_invoker = true);
alter view silver.instamart          set (security_invoker = true);
alter view silver.jiomart            set (security_invoker = true);
alter view silver.demo               set (security_invoker = true);