-- rollback 050: return the 10 views to owner-rights execution (the pre-050 state)
alter view silver.demo               reset (security_invoker);
alter view silver.jiomart            reset (security_invoker);
alter view silver.instamart          reset (security_invoker);
alter view silver.zepto              reset (security_invoker);
alter view silver.blinkit            reset (security_invoker);
alter view silver.v_wide             reset (security_invoker);
alter view silver.v_sku_listing      reset (security_invoker);
alter view silver.v_data_freshness   reset (security_invoker);
alter view silver.v_reading_current  reset (security_invoker);
alter view silver.v_reading          reset (security_invoker);
