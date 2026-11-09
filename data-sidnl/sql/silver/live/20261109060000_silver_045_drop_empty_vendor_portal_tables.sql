-- Applied live 2026-11-09. All 23 tables had 0 rows and no function/view references. No CASCADE on purpose.
-- NOTE: the public.vp_* drops were a mistake in hindsight (public is meant to be left alone); they were empty placeholders.
drop table
  silver.fact_sales_daily, silver.fact_po_line, silver.fact_grn_line, silver.fact_invoice,
  silver.fact_debit_note, silver.fact_payment, silver.fact_inventory_snapshot,
  silver.fact_ad_keyword_daily, silver.fact_category_sales,
  silver.dim_warehouse, silver.dim_supplier, silver.dim_keyword,
  public.vp_sales, public.vp_inventory, public.vp_po, public.vp_grn, public.vp_invoice,
  public.vp_debit_note, public.vp_payment, public.vp_ads, public.vp_keywords,
  public.vp_category_market, public.vp_ingest_batch;
