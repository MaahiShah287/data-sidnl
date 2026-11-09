-- =============================================================================
-- gold_102_lean_metric_tables
-- ARCHIVED ALTERNATIVE: this table-based migration is not part of the confirmed
-- live Gold state (gold migrations 060-063 are view-based). Do not apply it.
-- One narrow table per metric in the "Business Analytics Metrics - Formula
-- Reference" PDF. Each table holds ONLY its grain keys + the metric value.
--   * products are referenced by sidnl_id only; names/brand/category live once
--     in gold.dim_sidnl / gold.dim_brand (join when displaying).
--   * platform = 'ALL' and city_slug = 'ALL' rows are the cross-platform /
--     all-city totals (ratios recomputed from summed counts, never averaged).
--   * every value is computed from silver (through the gold base tables that
--     gold.refresh_all() builds from silver). No mock rows. Metrics whose
--     inputs are not loaded (sales, PO/GRN, finance, BE stock, weights,
--     targets, thresholds, keyword feeds) have an empty table that fills on
--     the next refresh once the input exists.
--   * pipeline internals (staging, registry, refresh code) live in schema
--     gold_stage, not in gold.
-- Replaces the wide gold_100 metric tables created earlier the same day.
-- gold.metric_catalog and every pre-existing gold table/view are untouched.
-- =============================================================================

create schema if not exists gold_stage;
revoke all on schema gold_stage from public;

-- ---------------------------------------------- remove the wide gold_100 set
drop function if exists gold.refresh_metrics(boolean);
do $$
declare t text;
begin
  foreach t in array array[
    'dim_sidnl','metric_registry','shelf_sidnl_daily',
    'metric_mrp','metric_sp','metric_avg_sp','metric_discount_amount','metric_discount_pct','metric_weighted_discount_pct',
    'metric_qty_sold','metric_sales_value_mrp','metric_brand_contribution','metric_market_share','metric_market_size',
    'metric_assortment','metric_assortment_coverage','metric_osa','metric_avg_osa','metric_osa_d1_d2_d3',
    'metric_dark_store_listing','metric_weighted_listing','metric_weighted_osa',
    'metric_inventory_fe','metric_inventory_be','metric_inventory_fe_be','metric_inventory_value','metric_drr','metric_doi',
    'metric_days_to_expiry','metric_slow_moving','metric_delivery_time_delay','metric_fulfilment_fill_deficit',
    'metric_po_grn_amounts_units','metric_critical_skus','metric_priority','metric_psl','metric_est_lost_units',
    'metric_approved_tds_payable','metric_credit_days_due','metric_invoice_dn_values','metric_fe_be_inventory_rca',
    'metric_rca_checks','metric_sales_contribution','metric_sales_impact','metric_overall_sov','metric_organic_paid_sov',
    'metric_top_of_search_sov','metric_category_impression_share','metric_competitor_share_discount_asp','metric_ad_spend',
    'metric_kw_vol','metric_top_cities_skus','metric_price_diff','metric_threshold_diff','metric_overview_kpi',
    'metric_osa_trend_daily','metric_brand_osa_daily']
  loop
    execute format('drop table if exists gold.%I', t);
  end loop;
end $$;
delete from gold.refresh_state where key like 'metric\_shelf:%' or key like 'metric:%';

-- ---------------------------------------------------------------- dimensions
create table gold.dim_sidnl (
  sidnl_id text primary key, brand_key text, canonical_name text, variant text,
  size_value numeric, size_unit text, pack_count integer, category_path text);
create index ix_dim_sidnl_brand on gold.dim_sidnl (brand_key);
alter table gold.dim_brand add column if not exists is_client boolean not null default false;

-- ---------------------------------------------------------- table generator
-- grains:  P  = <date>, sidnl_id, platform, city_slug          (product x city)
--          PO = as_of_date, sidnl_id, platform                  (product, no city)
--          B  = <date>, platform, city_slug, brand_key          (brand)
--          S  = obs_date, platform, category_l1_id, category_l2_id, city_slug, sidnl_id (category shelf)
--          I  = as_of_date, platform, invoice_number            (invoice)
--          K  = obs_date, platform, brand_key, keyword, city_slug (keyword)
create temp table _def (tbl text, grain text, dcol text, vcols text) on commit drop;
insert into _def values
 -- 1. overview: sales, market & pricing
 ('metric_sales_value_mrp','P','sales_date','sales_value_mrp numeric(16,2)'),
 ('metric_qty_sold','P','sales_date','qty_sold bigint'),
 ('metric_market_share','MS','period_date','market_share_pct numeric(7,3)'),
 ('metric_market_size','MS','period_date','est_market_size numeric(16,2)'),
 ('metric_avg_sp','P','obs_date','avg_sp numeric(12,2)'),
 ('metric_discount_amount','P','obs_date','discount_amount numeric(12,2)'),
 ('metric_discount_pct','P','obs_date','discount_pct numeric(8,2)'),
 ('metric_weighted_discount_pct','P','obs_date','weighted_discount_pct numeric(8,2)'),
 ('metric_brand_contribution','B','sales_date','brand_contribution_pct numeric(7,3)'),
 -- 2. assortment, listing & availability
 ('metric_assortment','B','obs_date','assortment integer'),
 ('metric_assortment_coverage','B','obs_date','assortment_coverage_pct numeric(8,2)'),
 ('metric_dark_store_listing','P','as_of_date','listing_pct numeric(8,2)'),
 ('metric_weighted_listing','P','as_of_date','weighted_listing_pct numeric(8,2)'),
 ('metric_osa','P','obs_date','osa_pct numeric(8,2)'),
 ('metric_weighted_osa','P','obs_date','weighted_osa_pct numeric(8,2)'),
 ('metric_osa_d1_d2_d3','P','as_of_date','osa_d1 numeric(8,2), osa_d2 numeric(8,2), osa_d3 numeric(8,2)'),
 -- 3. inventory & stock health
 ('metric_inventory_fe','P','as_of_date','inventory_fe bigint'),
 ('metric_inventory_be','P','as_of_date','inventory_be bigint'),
 ('metric_inventory_fe_be','P','as_of_date','inventory_fe_be bigint'),
 ('metric_drr','P','as_of_date','drr numeric(12,3)'),
 ('metric_doi_fe','P','as_of_date','doi_fe numeric(10,1)'),
 ('metric_doi_be','P','as_of_date','doi_be numeric(10,1)'),
 ('metric_doi_fe_be','P','as_of_date','doi_fe_be numeric(10,1)'),
 ('metric_inventory_value','P','as_of_date','inventory_value numeric(16,2)'),
 ('metric_be_inventory_value','P','as_of_date','be_inventory_value numeric(16,2)'),
 ('metric_days_to_expiry','PB','as_of_date','days_to_expiry integer'),
 ('metric_slow_moving','PB','as_of_date','is_slow_moving boolean'),
 -- 4. purchase orders & fulfilment
 ('metric_po_amount','PO','as_of_date','po_amount numeric(16,2)'),
 ('metric_po_units','PO','as_of_date','po_units bigint'),
 ('metric_grn_amount','PO','as_of_date','grn_amount numeric(16,2)'),
 ('metric_grn_units','PO','as_of_date','grn_units bigint'),
 ('metric_invoice_amount','PO','as_of_date','invoice_amount numeric(16,2)'),
 ('metric_invoice_qty','PO','as_of_date','invoice_qty bigint'),
 ('metric_dn_amount','PO','as_of_date','dn_amount numeric(16,2)'),
 ('metric_dn_amount_incl_tax','PO','as_of_date','dn_amount_incl_tax numeric(16,2)'),
 ('metric_fulfilment_gap','PO','as_of_date','fulfilment_gap bigint'),
 ('metric_fill_rate_pct','PO','as_of_date','fill_rate_pct numeric(7,3)'),
 ('metric_deficit_pct','PO','as_of_date','deficit_pct numeric(7,3)'),
 ('metric_open_pos','PO','as_of_date','open_pos integer'),
 ('metric_avg_delivery_time','PO','as_of_date','avg_delivery_days numeric(8,2)'),
 ('metric_delivery_delay','PO','as_of_date','delivery_delay_days numeric(8,2)'),
 ('metric_scheduled_lead_time','PO','as_of_date','scheduled_lead_days numeric(8,2)'),
 -- 5. priority, critical SKUs & potential loss
 ('metric_priority','P','as_of_date','priority text'),
 ('metric_critical_skus','P','as_of_date','latest_osa_pct numeric(8,2)'),
 ('metric_est_lost_units','P','as_of_date','est_lost_units numeric(14,2)'),
 ('metric_psl','P','as_of_date','psl_value numeric(16,2)'),
 -- 6. invoices, payments & debit notes
 ('metric_grn_value','PO','as_of_date','grn_value numeric(16,2)'),
 ('metric_invoice_value_incl_tax','PO','as_of_date','invoice_value_incl_tax numeric(16,2)'),
 ('metric_dn_value_incl_tax','PO','as_of_date','dn_value_incl_tax numeric(16,2)'),
 ('metric_grn_qty_diff','PO','as_of_date','grn_qty_diff bigint'),
 ('metric_grn_amount_diff','PO','as_of_date','grn_amount_diff numeric(16,2)'),
 ('metric_dn_qty','PO','as_of_date','dn_qty bigint'),
 ('metric_credit_days','I','as_of_date','credit_days integer'),
 ('metric_due_status','I','as_of_date','due_status text'),
 ('metric_approved_amount','I','as_of_date','approved_amount numeric(16,2)'),
 ('metric_tds_amount','I','as_of_date','tds_amount numeric(16,2)'),
 ('metric_amount_payable','I','as_of_date','amount_payable numeric(16,2)'),
 ('metric_advance_paid','I','as_of_date','advance_paid numeric(16,2)'),
 ('metric_payment_amount','I','as_of_date','payment_amount numeric(16,2)'),
 -- 7. availability RCA (OSA D-n, FE/BE, DOI reuse the tables above; RCA checks = view)
 ('metric_sales_contribution','P','sales_date','sales_contribution_pct numeric(7,3)'),
 ('metric_sales_impact','P','as_of_date','sales_impact_pct numeric(7,3)'),
 -- 8. visibility & keyword insights
 ('metric_kw_vol','K','obs_date','kw_volume_monthly bigint'),
 ('metric_overall_sov','S','obs_date','overall_sov_pct numeric(8,2)'),
 ('metric_organic_sov','S','obs_date','organic_sov_pct numeric(8,2)'),
 ('metric_paid_sov','S','obs_date','paid_sov_pct numeric(8,2)'),
 ('metric_top_of_search_sov','S','obs_date','top_of_search_sov_pct numeric(8,2)'),
 ('metric_top_of_search_organic_sov','S','obs_date','top_of_search_organic_sov_pct numeric(8,2)'),
 ('metric_top_of_search_paid_sov','S','obs_date','top_of_search_paid_sov_pct numeric(8,2)'),
 ('metric_category_impression_share','S','obs_date','category_impression_share_pct numeric(8,2)'),
 ('metric_competitor_market_share','MS','period_date','competitor_market_share_pct numeric(7,3)'),
 ('metric_competitor_discount_pct','S','obs_date','competitor_discount_pct numeric(8,2)'),
 ('metric_competitor_avg_sp','S','obs_date','competitor_avg_sp numeric(12,2)'),
 ('metric_ad_spend','K','obs_date','ad_spend numeric(14,2)'),
 -- 9. pricing - price parity
 ('metric_mrp','P','obs_date','mrp numeric(12,2)'),
 ('metric_sp','P','obs_date','sp numeric(12,2)'),
 ('metric_price_diff','P','obs_date','price_diff numeric(12,2)'),
 ('metric_price_diff_pct','P','obs_date','price_diff_pct numeric(8,2)'),
 ('metric_threshold_diff','P','obs_date','threshold_diff numeric(12,2)');

do $$
declare r record; k text; ix text;
begin
  for r in select * from _def loop
    k := case r.grain
      when 'P'  then format('%I date, sidnl_id text, platform text, city_slug text', r.dcol)
      when 'PB' then format('%I date, sidnl_id text, platform text, city_slug text, batch_no text', r.dcol)
      when 'PO' then format('%I date, sidnl_id text, platform text', r.dcol)
      when 'B'  then format('%I date, platform text, city_slug text, brand_key text', r.dcol)
      when 'MS' then format('%I date, platform text, city_slug text, brand_key text, category_l1_id text, category_l2_id text', r.dcol)
      when 'S'  then format('%I date, platform text, category_l1_id text, category_l2_id text, city_slug text, sidnl_id text', r.dcol)
      when 'I'  then format('%I date, platform text, invoice_number text', r.dcol)
      when 'K'  then format('%I date, platform text, brand_key text, keyword text, city_slug text', r.dcol)
    end;
    execute format('create table gold.%I (%s, %s, primary key (%s))', r.tbl, k, r.vcols,
                   regexp_replace(regexp_replace(k, ' (date|text)', '', 'g'), '"', '', 'g'));
    execute format('alter table gold.%I enable row level security', r.tbl);
    if r.grain in ('P','PB','PO','S') then
      execute format('create index %I on gold.%I (sidnl_id)', 'ix_' || r.tbl || '_sidnl', r.tbl);
    elsif r.grain in ('B','MS','K') then
      execute format('create index %I on gold.%I (brand_key)', 'ix_' || r.tbl || '_brand', r.tbl);
    end if;
  end loop;
end $$;

create table gold.metric_avg_osa (
  sidnl_id text, platform text, city_slug text,
  from_date date, to_date date, avg_osa_pct numeric(8,2), period_osa_pct numeric(8,2),
  primary key (sidnl_id, platform, city_slug));
create table gold.metric_top_cities_skus (
  as_of_date date, platform text, brand_key text, dimension text, measure text, rank integer,
  member_id text, measure_value numeric(16,3),
  primary key (platform, brand_key, dimension, measure, rank));
alter table gold.dim_sidnl enable row level security;
alter table gold.metric_avg_osa enable row level security;
alter table gold.metric_top_cities_skus enable row level security;

-- RCA checks: a view over the metric tables, no stored copy
create view gold.v_rca_checks with (security_invoker = true) as
with k as (
  select as_of_date, sidnl_id, platform, city_slug from gold.metric_osa_d1_d2_d3
  union select as_of_date, sidnl_id, platform, city_slug from gold.metric_inventory_fe
)
select k.as_of_date, k.sidnl_id, k.platform, k.city_slug,
       o.osa_d1, o.osa_d2, o.osa_d3, fe.inventory_fe, be.inventory_be, d.drr,
       df.doi_fe, db.doi_be, dfb.doi_fe_be, op.open_pos, pu.po_units, pa.po_amount
from k
left join gold.metric_osa_d1_d2_d3 o  using (as_of_date, sidnl_id, platform, city_slug)
left join gold.metric_inventory_fe fe using (as_of_date, sidnl_id, platform, city_slug)
left join gold.metric_inventory_be be using (as_of_date, sidnl_id, platform, city_slug)
left join gold.metric_drr d           using (as_of_date, sidnl_id, platform, city_slug)
left join gold.metric_doi_fe df       using (as_of_date, sidnl_id, platform, city_slug)
left join gold.metric_doi_be db       using (as_of_date, sidnl_id, platform, city_slug)
left join gold.metric_doi_fe_be dfb   using (as_of_date, sidnl_id, platform, city_slug)
left join gold.metric_open_pos op     using (as_of_date, sidnl_id, platform)
left join gold.metric_po_units pu     using (as_of_date, sidnl_id, platform)
left join gold.metric_po_amount pa    using (as_of_date, sidnl_id, platform);

-- ------------------------------------------------------------ gold_stage
create table gold_stage.metric_registry (
  metric_table text primary key, pdf_section integer, metric_name text, catalog_key text,
  status text, row_count bigint, last_refreshed_at timestamptz);

create table gold_stage.shelf_sidnl_daily (
  obs_date date, platform text, category_l1_id text, category_l2_id text, city_slug text, sidnl_id text,
  brand_key text, imp integer, org integer, paid integer, top integer, top_org integer, top_paid integer,
  sum_sp numeric, n_sp integer, sum_mrp numeric, sum_disc numeric,
  primary key (obs_date, platform, category_l1_id, category_l2_id, city_slug, sidnl_id));

create table gold_stage.refresh_state (key text primary key, value text, updated_at timestamptz not null default now());

create or replace function gold_stage.reload(p_table text, p_select text)
returns bigint language plpgsql
set search_path to 'gold', 'silver', 'public', 'pg_temp'
as $$
declare n bigint;
begin
  execute format('delete from gold.%I', p_table);
  execute format('insert into gold.%I %s', p_table, p_select);
  get diagnostics n = row_count;
  return n;
end $$;

insert into gold_stage.metric_registry (metric_table, pdf_section, metric_name, catalog_key) values
 ('metric_sales_value_mrp',1,'Sales value at MRP / Sales (MRP)','sales_value_mrp'),
 ('metric_qty_sold',1,'Quantity sold','qty_sold'),
 ('metric_market_share',1,'Market share (%)','market_share'),
 ('metric_market_size',1,'Estimated market size','market_size'),
 ('metric_avg_sp',1,'Average selling price','avg_sp'),
 ('metric_discount_amount',1,'Discount amount','discount_amount'),
 ('metric_discount_pct',1,'Discount (%)','discount_pct'),
 ('metric_weighted_discount_pct',1,'Weighted discount (%)','weighted_discount_pct'),
 ('metric_brand_contribution',1,'Brand contribution (%)','brand_contribution'),
 ('metric_assortment',2,'Assortment','assortment'),
 ('metric_assortment_coverage',2,'Assortment coverage (%)','assortment_coverage'),
 ('metric_dark_store_listing',2,'Dark-store listing (%)','dark_store_listing'),
 ('metric_weighted_listing',2,'Weighted listing (%)','weighted_listing'),
 ('metric_osa',2,'OSA (%)','osa'),
 ('metric_weighted_osa',2,'Weighted OSA (%)','weighted_osa'),
 ('metric_avg_osa',2,'Average OSA (%)','avg_osa'),
 ('metric_osa_d1_d2_d3',2,'OSA D-1 / D-2 / D-3','osa_d1_d2_d3'),
 ('metric_inventory_fe',3,'Inventory (FE)','inventory_fe'),
 ('metric_inventory_be',3,'Inventory (BE)','inventory_be'),
 ('metric_inventory_fe_be',3,'Inventory (FE+BE)','inventory_fe_be'),
 ('metric_drr',3,'DRR','drr'),
 ('metric_doi_fe',3,'DOI (FE)','doi'),
 ('metric_doi_be',3,'DOI (BE)','doi'),
 ('metric_doi_fe_be',3,'DOI (FE+BE)','doi'),
 ('metric_inventory_value',3,'Inventory value','inventory_value'),
 ('metric_be_inventory_value',3,'BE inventory value','inventory_value'),
 ('metric_days_to_expiry',3,'Days to expiry','days_to_expiry'),
 ('metric_slow_moving',3,'Slow-moving stock','slow_moving'),
 ('metric_po_amount',4,'PO amount','po_grn_amounts_units'),
 ('metric_po_units',4,'PO units','po_grn_amounts_units'),
 ('metric_grn_amount',4,'GRN amount','po_grn_amounts_units'),
 ('metric_grn_units',4,'GRN units','po_grn_amounts_units'),
 ('metric_invoice_amount',4,'Invoice amount','po_grn_amounts_units'),
 ('metric_invoice_qty',4,'Invoice quantity','po_grn_amounts_units'),
 ('metric_dn_amount',4,'DN amount','po_grn_amounts_units'),
 ('metric_dn_amount_incl_tax',4,'DN amount (incl. tax)','po_grn_amounts_units'),
 ('metric_fulfilment_gap',4,'Fulfilment gap','fulfilment_fill_deficit'),
 ('metric_fill_rate_pct',4,'Fill rate (%)','fulfilment_fill_deficit'),
 ('metric_deficit_pct',4,'Deficit (%)','fulfilment_fill_deficit'),
 ('metric_open_pos',4,'Open POs','fulfilment_fill_deficit'),
 ('metric_avg_delivery_time',4,'Average delivery time','delivery_time_delay'),
 ('metric_delivery_delay',4,'Delivery delay','delivery_time_delay'),
 ('metric_scheduled_lead_time',4,'Scheduled lead time','delivery_time_delay'),
 ('metric_priority',5,'Priority','priority'),
 ('metric_critical_skus',5,'Critical SKUs','critical_skus'),
 ('metric_est_lost_units',5,'Estimated lost units','est_lost_units'),
 ('metric_psl',5,'PSL / potential sales loss','psl'),
 ('metric_grn_value',6,'GRN value','invoice_dn_values'),
 ('metric_invoice_value_incl_tax',6,'Invoice value (incl. tax)','invoice_dn_values'),
 ('metric_dn_value_incl_tax',6,'Debit note value (incl. tax)','invoice_dn_values'),
 ('metric_grn_qty_diff',6,'GRN quantity difference','invoice_dn_values'),
 ('metric_grn_amount_diff',6,'GRN amount difference','invoice_dn_values'),
 ('metric_dn_qty',6,'DN quantity','invoice_dn_values'),
 ('metric_credit_days',6,'Credit days','credit_days_due'),
 ('metric_due_status',6,'Due status','credit_days_due'),
 ('metric_approved_amount',6,'Approved amount','approved_tds_payable'),
 ('metric_tds_amount',6,'TDS amount','approved_tds_payable'),
 ('metric_amount_payable',6,'Amount payable','approved_tds_payable'),
 ('metric_advance_paid',6,'Advance paid','approved_tds_payable'),
 ('metric_payment_amount',6,'Payment amount','approved_tds_payable'),
 ('metric_sales_contribution',7,'Sales contribution (%)','sales_contribution'),
 ('metric_sales_impact',7,'Sales impact (%)','sales_impact'),
 ('v_rca_checks',7,'RCA checks (view)','rca_checks'),
 ('metric_kw_vol',8,'KW VOL (monthly)','kw_vol'),
 ('metric_overall_sov',8,'Overall SOV (%)','overall_sov'),
 ('metric_organic_sov',8,'Organic SOV (%)','organic_paid_sov'),
 ('metric_paid_sov',8,'Paid SOV (%)','organic_paid_sov'),
 ('metric_top_of_search_sov',8,'Top of Search SOV','top_of_search_sov'),
 ('metric_top_of_search_organic_sov',8,'Top of Search Organic SOV','top_of_search_sov'),
 ('metric_top_of_search_paid_sov',8,'Top of Search Paid SOV','top_of_search_sov'),
 ('metric_category_impression_share',8,'Category Impression Share','category_impression_share'),
 ('metric_competitor_market_share',8,'Competitor market share','competitor_share_discount_asp'),
 ('metric_competitor_discount_pct',8,'Competitor discount (%)','competitor_share_discount_asp'),
 ('metric_competitor_avg_sp',8,'Competitor average SP','competitor_share_discount_asp'),
 ('metric_ad_spend',8,'Ad spend','ad_spend'),
 ('metric_top_cities_skus',8,'Top cities / top SKUs','top_cities_skus'),
 ('metric_mrp',9,'MRP','mrp'),
 ('metric_sp',9,'SP','sp'),
 ('metric_price_diff',9,'Price difference','price_diff'),
 ('metric_price_diff_pct',9,'Price difference (%)','price_diff'),
 ('metric_threshold_diff',9,'Threshold difference','threshold_diff');
update gold_stage.metric_registry r set status = c.status from gold.metric_catalog c where c.metric_key = r.catalog_key;

-- =============================================================================
-- refresh
-- =============================================================================
create or replace function gold_stage.refresh_metrics(p_full boolean default false)
returns jsonb
language plpgsql
set search_path to 'gold', 'silver', 'public', 'pg_temp'
as $function$
declare
  v_asof date := (now() at time zone 'Asia/Kolkata')::date;
  v_stats jsonb := '{}'::jsonb;
  v_top numeric; v_dirty date[]; v_cfg text; v_all boolean;
  v_job record;
begin
  select value into v_top from gold.cfg_threshold where key = 'top_of_search_n';

  drop table if exists _cfg;
  create temp table _cfg on commit drop as
    select v_asof as asof,
           (select value from gold.cfg_threshold where key = 'parity_tolerance_pct') tol,
           (select value from gold.cfg_threshold where key = 'critical_osa_pct') crit,
           (select value from gold.cfg_threshold where key = 'priority_high_osa_pct') hi,
           (select value from gold.cfg_threshold where key = 'priority_medium_osa_pct') med,
           (select value_text from gold.cfg_threshold where key = 'parity_reference_platform') refplat;

  -- product_key -> sidnl_id
  drop table if exists _pk;
  create temp table _pk on commit drop as
    select product_key, sidnl_id, brand_key, platform, platform_product_id
    from gold.dim_product where sidnl_id is not null;
  create index on _pk (product_key);
  analyze _pk;

  -- dimensions
  delete from gold.dim_sidnl;
  insert into gold.dim_sidnl
  select cp.sidnl_id, cp.brand_key, cp.canonical_name, cp.variant, cp.size_value, cp.size_unit, cp.pack_count,
         coalesce(nullif(concat_ws(' > ', cp.category_l1, cp.category_l2, cp.category_l3), ''),
                  (select max(gp.category_path) from gold.dim_product gp where gp.sidnl_id = cp.sidnl_id))
  from silver.canonical_product cp
  where exists (select 1 from _pk k where k.sidnl_id = cp.sidnl_id);
  update gold.dim_brand b
     set is_client = exists (select 1 from silver.brand_scope s where s.brand_key = b.brand_key and s.is_enabled)
   where b.is_client is distinct from exists (select 1 from silver.brand_scope s where s.brand_key = b.brand_key and s.is_enabled);

  -- ------------------------------------------------------------ work tables
  drop table if exists _price, _osa, _rd, _inv, _be, _drr, _hl, _po, _dt, _ir, _sales, _w, _fp, _sh;
  create temp table _price on commit drop as
    select p.obs_date, k.sidnl_id, case when grouping(p.platform) = 1 then 'ALL' else p.platform end platform, p.city_slug,
           round(sum(p.avg_mrp * p.readings) / nullif(sum(p.readings), 0), 2) mrp,
           round(sum(p.avg_sp * p.readings) / nullif(sum(p.readings), 0), 2) sp,
           round(sum(p.avg_discount_amount * p.readings) / nullif(sum(p.readings), 0), 2) disc_amt,
           round(sum(p.avg_discount_pct * p.readings) / nullif(sum(p.readings), 0), 2) disc_pct,
           round(100.0 * sum(p.avg_discount_amount * p.readings) / nullif(sum(p.avg_mrp * p.readings), 0), 2) wdisc
    from gold.price_daily p join _pk k on k.product_key = p.product_key
    group by grouping sets ((p.obs_date, k.sidnl_id, p.platform, p.city_slug), (p.obs_date, k.sidnl_id, p.city_slug));

  create temp table _osa on commit drop as
    select o.obs_date, k.sidnl_id, case when grouping(o.platform) = 1 then 'ALL' else o.platform end platform, o.city_slug,
           sum(o.eligible_obs) e, sum(o.available_obs) a
    from gold.osa_daily o join _pk k on k.product_key = o.product_key
    group by grouping sets ((o.obs_date, k.sidnl_id, o.platform, o.city_slug), (o.obs_date, k.sidnl_id, o.city_slug));

  create temp table _rd on commit drop as
    select r.obs_date, r.platform, r.brand_key, coalesce(r.city_slug, '(unknown)') city_slug, k.sidnl_id,
           r.store_key, r.is_listed, r.is_available, r.osa_eligible, r.observed_at, r.reading_key
    from gold.v_valid_reading r join _pk k on k.product_key = r.product_key;

  create temp table _inv on commit drop as
    select i.as_of_date, k.sidnl_id, case when grouping(i.platform) = 1 then 'ALL' else i.platform end platform, i.city_slug,
           sum(i.fe_units_total) fe
    from gold.inventory_summary i join _pk k on k.product_key = i.product_key
    group by grouping sets ((i.as_of_date, k.sidnl_id, i.platform, i.city_slug), (i.as_of_date, k.sidnl_id, i.city_slug));

  create temp table _be on commit drop as
    select d.as_of_date, k.sidnl_id, case when grouping(d.platform) = 1 then 'ALL' else d.platform end platform, d.city_slug,
           sum(d.be_units) be
    from gold.doi_current d join _pk k on k.product_key = d.product_key where d.be_units is not null
    group by grouping sets ((d.as_of_date, k.sidnl_id, d.platform, d.city_slug), (d.as_of_date, k.sidnl_id, d.city_slug));

  create temp table _drr on commit drop as
    select d.as_of_date, k.sidnl_id, case when grouping(d.platform) = 1 then 'ALL' else d.platform end platform, d.city_slug,
           round(sum(d.units_sold)::numeric / nullif(max(d.window_days), 0), 3) drr
    from gold.drr_daily d join _pk k on k.product_key = d.product_key
    group by grouping sets ((d.as_of_date, k.sidnl_id, d.platform, d.city_slug), (d.as_of_date, k.sidnl_id, d.city_slug));

  create temp table _hl on commit drop as
    select h.as_of_date, k.sidnl_id, case when grouping(h.platform) = 1 then 'ALL' else h.platform end platform, h.city_slug,
           round(100.0 * sum(h.in_stock_stores) / nullif(sum(h.stores_checked), 0), 2) osa, sum(h.psl_proxy) psl
    from gold.sku_health_current h join _pk k on k.product_key = h.product_key
    group by grouping sets ((h.as_of_date, k.sidnl_id, h.platform, h.city_slug), (h.as_of_date, k.sidnl_id, h.city_slug));

  create temp table _po on commit drop as
    select f.as_of_date, k.sidnl_id, case when grouping(f.platform) = 1 then 'ALL' else f.platform end platform,
           sum(f.po_amount) po_amount, sum(f.po_units) po_units, sum(f.grn_amount) grn_amount, sum(f.grn_units) grn_units,
           sum(f.invoice_amount) invoice_amount, sum(f.invoice_qty) invoice_qty, sum(f.dn_amount) dn_amount,
           sum(f.dn_amount_incl_tax) dn_amount_incl_tax
    from gold.po_fulfilment f join _pk k on k.product_key = f.product_key
    group by grouping sets ((f.as_of_date, k.sidnl_id, f.platform), (f.as_of_date, k.sidnl_id));

  create temp table _dt on commit drop as
    select d.as_of_date, k.sidnl_id, case when grouping(d.platform) = 1 then 'ALL' else d.platform end platform,
           round(sum(d.avg_delivery_days * d.delivered_pos) / nullif(sum(d.delivered_pos), 0), 2) dd,
           round(sum(d.avg_delivery_delay_days * d.delivered_pos) / nullif(sum(d.delivered_pos), 0), 2) dl,
           round(sum(d.avg_scheduled_lead_days * d.delivered_pos) / nullif(sum(d.delivered_pos), 0), 2) lt
    from gold.delivery_time d join _pk k on k.product_key = d.product_key
    group by grouping sets ((d.as_of_date, k.sidnl_id, d.platform), (d.as_of_date, k.sidnl_id));

  create temp table _ir on commit drop as
    select i.as_of_date, k.sidnl_id, case when grouping(i.platform) = 1 then 'ALL' else i.platform end platform,
           sum(i.grn_value) grn_value, sum(i.invoice_value_incl_tax) inv, sum(i.dn_value_incl_tax) dn,
           sum(i.grn_qty_diff) qd, sum(i.grn_amount_diff) ad, sum(i.dn_qty) dn_qty
    from gold.invoice_recon i join _pk k on k.product_key = i.product_key
    group by grouping sets ((i.as_of_date, k.sidnl_id, i.platform), (i.as_of_date, k.sidnl_id));

  create temp table _sales on commit drop as
    select s.sales_date, k.sidnl_id, case when grouping(s.platform) = 1 then 'ALL' else s.platform end platform, s.city_slug,
           max(k.brand_key) brand_key, sum(s.units_sold) units, sum(s.sales_mrp) sales_mrp
    from gold.sales_daily s join _pk k on k.product_key = s.product_key
    group by grouping sets ((s.sales_date, k.sidnl_id, s.platform, s.city_slug), (s.sales_date, k.sidnl_id, s.city_slug));

  create temp table _w on commit drop as
    select store_key, "store_weight (weight per store, e.g. store sales)" w from silver.dim_store
    where "store_weight (weight per store, e.g. store sales)" > 0;

  -- ------------------------------------- category-shelf staging (incremental)
  v_cfg := md5(concat_ws('|', v_top::text,
             (select string_agg(concat_ws(':', platform, l1_id, l2_id), ',' order by platform, l1_id, l2_id) from silver.category_scope),
             (select md5(string_agg(product_key || '=' || sidnl_id, ',' order by product_key)) from _pk)));
  v_all := p_full or coalesce((select value from gold_stage.refresh_state where key = 'shelf:config'), '') <> v_cfg;

  create temp table _fp on commit drop as
    select obs_date, concat_ws('/', count(*), count(*) filter (where dq_status = 'valid' and store_key is not null), max(loaded_at)) fp
    from silver.fact_shelf_position group by obs_date;
  select coalesce(array_agg(f.obs_date), '{}') into v_dirty
  from _fp f left join gold_stage.refresh_state s on s.key = 'shelf:' || f.obs_date::text
  where v_all or s.value is distinct from f.fp;

  if v_all then
    delete from gold_stage.shelf_sidnl_daily;
  else
    delete from gold_stage.shelf_sidnl_daily where obs_date = any(v_dirty) or obs_date not in (select obs_date from _fp);
  end if;

  if cardinality(v_dirty) > 0 then
    insert into gold_stage.shelf_sidnl_daily
    with snap as (
      select distinct on (platform, l1_id, l2_id, store_key, obs_date) snapshot_id
      from silver.fact_shelf_position
      where store_key is not null and obs_date = any(v_dirty)
      order by platform, l1_id, l2_id, store_key, obs_date, observed_at desc, snapshot_id desc
    ), r as (
      select f.obs_date, f.platform, f.l1_id, f.l2_id, coalesce(f.city_slug, '(unknown)') c, k.sidnl_id,
             coalesce(f.brand_key, k.brand_key) brand_key, f.shelf_position, coalesce(f.is_ad, false) ad,
             f.mrp, f.selling_price, f.discount_pct
      from silver.fact_shelf_position f
      join snap s on s.snapshot_id = f.snapshot_id
      join _pk k on k.product_key = f.product_key
      join silver.category_scope cs on cs.platform = f.platform and cs.l1_id = f.l1_id and cs.l2_id = f.l2_id
      where f.dq_status = 'valid' and f.store_key is not null and f.obs_date = any(v_dirty)
    )
    select obs_date, platform, l1_id, l2_id, case when grouping(c) = 1 then 'ALL' else c end, sidnl_id, max(brand_key),
           count(*)::int, (count(*) filter (where not ad))::int, (count(*) filter (where ad))::int,
           (count(*) filter (where shelf_position <= v_top))::int,
           (count(*) filter (where shelf_position <= v_top and not ad))::int,
           (count(*) filter (where shelf_position <= v_top and ad))::int,
           sum(selling_price), (count(selling_price))::int, sum(mrp) filter (where mrp > 0 and selling_price is not null),
           sum(mrp - selling_price) filter (where mrp > 0 and selling_price is not null)
    from r group by obs_date, platform, l1_id, l2_id, sidnl_id, rollup(c);

    insert into gold_stage.refresh_state (key, value)
      select 'shelf:' || obs_date::text, fp from _fp where obs_date = any(v_dirty)
    on conflict (key) do update set value = excluded.value, updated_at = now();
  end if;
  delete from gold_stage.refresh_state where key like 'shelf:2%' and substr(key, 7)::date not in (select obs_date from _fp);
  insert into gold_stage.refresh_state (key, value) values ('shelf:config', v_cfg)
    on conflict (key) do update set value = excluded.value, updated_at = now();

  create temp table _sh on commit drop as
    select s.*, m.m_imp, m.m_org, m.m_paid, m.m_top, m.m_top_org, m.m_top_paid, m.brands
    from gold_stage.shelf_sidnl_daily s
    join (select obs_date, platform, category_l1_id, category_l2_id, city_slug,
                 sum(imp) m_imp, sum(org) m_org, sum(paid) m_paid, sum(top) m_top, sum(top_org) m_top_org, sum(top_paid) m_top_paid,
                 count(distinct brand_key) brands
          from gold_stage.shelf_sidnl_daily group by 1, 2, 3, 4, 5) m
      using (obs_date, platform, category_l1_id, category_l2_id, city_slug);

  -- ------------------------------------------------------------ metric loads
  for v_job in select * from (values
    -- 1
    ('metric_sales_value_mrp', $q$select sales_date, sidnl_id, platform, city_slug, sales_mrp from _sales where sales_mrp is not null$q$),
    ('metric_qty_sold',        $q$select sales_date, sidnl_id, platform, city_slug, units from _sales where units is not null$q$),
    ('metric_market_share',    $q$select period_date, platform, city_slug, brand_key, category_l1_id, category_l2_id, market_share_pct from gold.market_share_daily where market_share_pct is not null$q$),
    ('metric_market_size',     $q$select period_date, platform, city_slug, brand_key, category_l1_id, category_l2_id, est_market_size from gold.market_share_daily where est_market_size is not null$q$),
    ('metric_avg_sp',          $q$select obs_date, sidnl_id, platform, city_slug, sp from _price where sp is not null$q$),
    ('metric_discount_amount', $q$select obs_date, sidnl_id, platform, city_slug, disc_amt from _price where disc_amt is not null$q$),
    ('metric_discount_pct',    $q$select obs_date, sidnl_id, platform, city_slug, disc_pct from _price where disc_pct is not null$q$),
    ('metric_weighted_discount_pct', $q$select obs_date, sidnl_id, platform, city_slug, wdisc from _price where wdisc is not null$q$),
    ('metric_brand_contribution', $q$
       select q.sales_date, q.platform, q.city_slug, q.brand_key, round(100.0 * q.bs / nullif(t.ts, 0), 3)
       from (select sales_date, platform, city_slug, brand_key, sum(sales_mrp) bs from _sales group by 1, 2, 3, 4) q
       join (select sales_date, platform, city_slug, sum(sales_mrp) ts from _sales group by 1, 2, 3) t using (sales_date, platform, city_slug)$q$),
    -- 2
    ('metric_assortment', $q$
       select obs_date, coalesce(platform, 'ALL'), coalesce(city_slug, 'ALL'), brand_key, count(distinct sidnl_id)::int
       from _rd where is_listed
       group by grouping sets ((obs_date, platform, brand_key, city_slug), (obs_date, platform, brand_key),
                               (obs_date, brand_key, city_slug), (obs_date, brand_key))$q$),
    ('metric_assortment_coverage', $q$
       with t as (select k.platform, k.brand_key, k.sidnl_id from gold.cfg_sku c
                  join _pk k on k.platform = c.platform and k.platform_product_id = c.platform_product_id where c.is_target),
       d as (select distinct r.obs_date, r.platform, r.brand_key, c.city_slug
             from _rd r cross join lateral (values (r.city_slug), ('ALL')) c(city_slug)
             where exists (select 1 from t where t.platform = r.platform and t.brand_key = r.brand_key)),
       l as (select distinct r.obs_date, r.platform, c.city_slug, r.sidnl_id
             from _rd r cross join lateral (values (r.city_slug), ('ALL')) c(city_slug) where r.is_listed)
       select d.obs_date, d.platform, d.city_slug, d.brand_key, round(100.0 * count(l.sidnl_id) / nullif(count(t.sidnl_id), 0), 2)
       from d join t on t.platform = d.platform and t.brand_key = d.brand_key
       left join l on l.obs_date = d.obs_date and l.platform = d.platform and l.city_slug = d.city_slug and l.sidnl_id = t.sidnl_id
       group by d.obs_date, d.platform, d.city_slug, d.brand_key$q$),
    ('metric_dark_store_listing', $q$
       select l.as_of_date, k.sidnl_id, case when grouping(l.platform) = 1 then 'ALL' else l.platform end, l.city_slug,
              round(100.0 * sum(l.listing_stores) / nullif(sum(l.eligible_stores), 0), 2)
       from gold.listing_snapshot l join _pk k on k.product_key = l.product_key
       group by grouping sets ((l.as_of_date, k.sidnl_id, l.platform, l.city_slug), (l.as_of_date, k.sidnl_id, l.city_slug))$q$),
    ('metric_weighted_listing', $q$
       with ls as (select distinct on (s.brand_key, s.store_key) s.brand_key, s.store_key, s.snapshot_id, s.platform,
                          coalesce(s.city_slug, '(unknown)') city_slug, w.w
                   from silver.fact_store_scan s join _w w on w.store_key = s.store_key where s.is_valid_denominator
                   order by s.brand_key, s.store_key, s.scanned_at desc, s.snapshot_id desc),
       cand as (select ls.*, k.sidnl_id from ls join _pk k on k.platform = ls.platform and k.brand_key = ls.brand_key),
       lst as (select distinct f.snapshot_id, k.sidnl_id from silver.fact_product_reading f join _pk k on k.product_key = f.product_key
               where f.source_type = 'brand_search' and f.dq_status = 'valid' and f.is_listed and f.snapshot_id in (select snapshot_id from ls))
       select (select asof from _cfg), c.sidnl_id, coalesce(c.platform, 'ALL'), coalesce(c.city_slug, 'ALL'),
              round(100.0 * coalesce(sum(c.w) filter (where l.sidnl_id is not null), 0) / nullif(sum(c.w), 0), 2)
       from cand c left join lst l on l.snapshot_id = c.snapshot_id and l.sidnl_id = c.sidnl_id
       group by grouping sets ((c.sidnl_id, c.platform, c.city_slug), (c.sidnl_id, c.platform), (c.sidnl_id, c.city_slug), (c.sidnl_id))$q$),
    ('metric_osa', $q$select obs_date, sidnl_id, platform, city_slug, round(100.0 * a / nullif(e, 0), 2) from _osa where e > 0$q$),
    ('metric_weighted_osa', $q$
       with x as (select distinct on (r.sidnl_id, r.store_key, r.obs_date) r.obs_date, r.platform, r.city_slug, r.sidnl_id, r.is_available, w.w
                  from _rd r join _w w on w.store_key = r.store_key
                  where r.osa_eligible and r.is_available is not null
                  order by r.sidnl_id, r.store_key, r.obs_date, r.observed_at desc, r.reading_key desc)
       select obs_date, sidnl_id, coalesce(platform, 'ALL'), coalesce(city_slug, 'ALL'),
              round(100.0 * coalesce(sum(w) filter (where is_available), 0) / nullif(sum(w), 0), 2)
       from x group by grouping sets ((obs_date, sidnl_id, platform, city_slug), (obs_date, sidnl_id, platform), (obs_date, sidnl_id, city_slug), (obs_date, sidnl_id))$q$),
    ('metric_avg_osa', $q$
       select sidnl_id, platform, city_slug, min(obs_date), max(obs_date),
              round(avg(100.0 * a / e), 2), round(100.0 * sum(a) / nullif(sum(e), 0), 2)
       from _osa where e > 0 group by sidnl_id, platform, city_slug$q$),
    ('metric_osa_d1_d2_d3', $q$
       select a.as_of_date, o.sidnl_id, o.platform, o.city_slug,
              round(100.0 * sum(o.a) filter (where o.obs_date = a.as_of_date - 1) / nullif(sum(o.e) filter (where o.obs_date = a.as_of_date - 1), 0), 2),
              round(100.0 * sum(o.a) filter (where o.obs_date = a.as_of_date - 2) / nullif(sum(o.e) filter (where o.obs_date = a.as_of_date - 2), 0), 2),
              round(100.0 * sum(o.a) filter (where o.obs_date = a.as_of_date - 3) / nullif(sum(o.e) filter (where o.obs_date = a.as_of_date - 3), 0), 2)
       from (select distinct as_of_date from gold.osa_dn union select asof from _cfg) a
       join _osa o on o.obs_date between a.as_of_date - 3 and a.as_of_date - 1
       group by a.as_of_date, o.sidnl_id, o.platform, o.city_slug$q$),
    -- 3
    ('metric_inventory_fe', $q$select as_of_date, sidnl_id, platform, city_slug, fe from _inv where fe is not null$q$),
    ('metric_inventory_be', $q$select as_of_date, sidnl_id, platform, city_slug, be from _be$q$),
    ('metric_inventory_fe_be', $q$select as_of_date, sidnl_id, platform, city_slug, coalesce(i.fe, 0) + b.be from _be b left join _inv i using (as_of_date, sidnl_id, platform, city_slug)$q$),
    ('metric_drr', $q$select as_of_date, sidnl_id, platform, city_slug, drr from _drr where drr is not null$q$),
    ('metric_doi_fe', $q$select as_of_date, sidnl_id, platform, city_slug, round(i.fe / d.drr, 1) from _inv i join _drr d using (as_of_date, sidnl_id, platform, city_slug) where d.drr > 0$q$),
    ('metric_doi_be', $q$select as_of_date, sidnl_id, platform, city_slug, round(b.be / d.drr, 1) from _be b join _drr d using (as_of_date, sidnl_id, platform, city_slug) where d.drr > 0$q$),
    ('metric_doi_fe_be', $q$select as_of_date, sidnl_id, platform, city_slug, round((coalesce(i.fe, 0) + b.be) / d.drr, 1)
                            from _be b join _drr d using (as_of_date, sidnl_id, platform, city_slug)
                            left join _inv i using (as_of_date, sidnl_id, platform, city_slug) where d.drr > 0$q$),
    ('metric_inventory_value', $q$
       select v.as_of_date, k.sidnl_id, case when grouping(v.platform) = 1 then 'ALL' else v.platform end, v.city_slug, sum(v.inventory_value)
       from gold.inventory_value v join _pk k on k.product_key = v.product_key where v.inventory_value is not null
       group by grouping sets ((v.as_of_date, k.sidnl_id, v.platform, v.city_slug), (v.as_of_date, k.sidnl_id, v.city_slug))$q$),
    ('metric_be_inventory_value', $q$
       select v.as_of_date, k.sidnl_id, case when grouping(v.platform) = 1 then 'ALL' else v.platform end, v.city_slug, sum(v.be_inventory_value)
       from gold.inventory_value v join _pk k on k.product_key = v.product_key where v.be_inventory_value is not null
       group by grouping sets ((v.as_of_date, k.sidnl_id, v.platform, v.city_slug), (v.as_of_date, k.sidnl_id, v.city_slug))$q$),
    ('metric_days_to_expiry', $q$select distinct on (e.as_of_date, k.sidnl_id, e.platform, e.city_slug, e.batch_no)
                                 e.as_of_date, k.sidnl_id, e.platform, e.city_slug, e.batch_no, e.days_to_expiry
                                 from gold.expiry_risk e join _pk k on k.product_key = e.product_key$q$),
    ('metric_slow_moving', $q$select distinct on (e.as_of_date, k.sidnl_id, e.platform, e.city_slug, e.batch_no)
                              e.as_of_date, k.sidnl_id, e.platform, e.city_slug, e.batch_no, e.is_slow_moving
                              from gold.expiry_risk e join _pk k on k.product_key = e.product_key where e.is_slow_moving is not null$q$),
    -- 4
    ('metric_po_amount', $q$select as_of_date, sidnl_id, platform, po_amount from _po where po_amount is not null$q$),
    ('metric_po_units', $q$select as_of_date, sidnl_id, platform, po_units from _po where po_units is not null$q$),
    ('metric_grn_amount', $q$select as_of_date, sidnl_id, platform, grn_amount from _po where grn_amount is not null$q$),
    ('metric_grn_units', $q$select as_of_date, sidnl_id, platform, grn_units from _po where grn_units is not null$q$),
    ('metric_invoice_amount', $q$select as_of_date, sidnl_id, platform, invoice_amount from _po where invoice_amount is not null$q$),
    ('metric_invoice_qty', $q$select as_of_date, sidnl_id, platform, invoice_qty from _po where invoice_qty is not null$q$),
    ('metric_dn_amount', $q$select as_of_date, sidnl_id, platform, dn_amount from _po where dn_amount is not null$q$),
    ('metric_dn_amount_incl_tax', $q$select as_of_date, sidnl_id, platform, dn_amount_incl_tax from _po where dn_amount_incl_tax is not null$q$),
    ('metric_fulfilment_gap', $q$select as_of_date, sidnl_id, platform, po_units - grn_units from _po where po_units is not null and grn_units is not null$q$),
    ('metric_fill_rate_pct', $q$select as_of_date, sidnl_id, platform, round(100.0 * grn_units / po_units, 3) from _po where po_units > 0$q$),
    ('metric_deficit_pct', $q$select as_of_date, sidnl_id, platform, round(100.0 * (po_units - grn_units) / po_units, 3) from _po where po_units > 0$q$),
    ('metric_open_pos', $q$
       select o.as_of_date, k.sidnl_id, case when grouping(o.platform) = 1 then 'ALL' else o.platform end, count(distinct o.po_number)::int
       from gold.open_pos o join _pk k on k.product_key = o.product_key
       group by grouping sets ((o.as_of_date, k.sidnl_id, o.platform), (o.as_of_date, k.sidnl_id))$q$),
    ('metric_avg_delivery_time', $q$select as_of_date, sidnl_id, platform, dd from _dt where dd is not null$q$),
    ('metric_delivery_delay', $q$select as_of_date, sidnl_id, platform, dl from _dt where dl is not null$q$),
    ('metric_scheduled_lead_time', $q$select as_of_date, sidnl_id, platform, lt from _dt where lt is not null$q$),
    -- 5
    ('metric_priority', $q$select h.as_of_date, h.sidnl_id, h.platform, h.city_slug,
                             case when h.osa < c.hi then 'High' when h.osa < c.med then 'Medium' else 'Low' end
                           from _hl h cross join _cfg c where h.osa is not null$q$),
    ('metric_critical_skus', $q$select h.as_of_date, h.sidnl_id, h.platform, h.city_slug, h.osa from _hl h cross join _cfg c where h.osa < c.crit$q$),
    ('metric_est_lost_units', $q$
       select p.as_of_date, k.sidnl_id, case when grouping(p.platform) = 1 then 'ALL' else p.platform end, p.city_slug, sum(p.est_lost_units)
       from gold.psl_daily p join _pk k on k.product_key = p.product_key where p.est_lost_units is not null
       group by grouping sets ((p.as_of_date, k.sidnl_id, p.platform, p.city_slug), (p.as_of_date, k.sidnl_id, p.city_slug))$q$),
    -- PSL: demand-based value from gold.psl_daily when loaded; otherwise the OOS-stores x SP proxy
    ('metric_psl', $q$
       with rp as (
         select p.as_of_date, k.sidnl_id, case when grouping(p.platform) = 1 then 'ALL' else p.platform end platform, p.city_slug, sum(p.psl_value) v
         from gold.psl_daily p join _pk k on k.product_key = p.product_key where p.psl_value is not null
         group by grouping sets ((p.as_of_date, k.sidnl_id, p.platform, p.city_slug), (p.as_of_date, k.sidnl_id, p.city_slug)))
       select as_of_date, sidnl_id, platform, city_slug, v from rp
       union all
       select h.as_of_date, h.sidnl_id, h.platform, h.city_slug, h.psl from _hl h
       where h.psl is not null and not exists (select 1 from rp)$q$),
    -- 6
    ('metric_grn_value', $q$select as_of_date, sidnl_id, platform, grn_value from _ir where grn_value is not null$q$),
    ('metric_invoice_value_incl_tax', $q$select as_of_date, sidnl_id, platform, inv from _ir where inv is not null$q$),
    ('metric_dn_value_incl_tax', $q$select as_of_date, sidnl_id, platform, dn from _ir where dn is not null$q$),
    ('metric_grn_qty_diff', $q$select as_of_date, sidnl_id, platform, qd from _ir where qd is not null$q$),
    ('metric_grn_amount_diff', $q$select as_of_date, sidnl_id, platform, ad from _ir where ad is not null$q$),
    ('metric_dn_qty', $q$select as_of_date, sidnl_id, platform, dn_qty from _ir where dn_qty is not null$q$),
    ('metric_credit_days', $q$select as_of_date, platform, invoice_number, credit_days from gold.payment_status where credit_days is not null$q$),
    ('metric_due_status', $q$select as_of_date, platform, invoice_number, due_status from gold.payment_status where due_status is not null$q$),
    ('metric_approved_amount', $q$select as_of_date, platform, invoice_number, approved_amount from gold.payment_status where approved_amount is not null$q$),
    ('metric_tds_amount', $q$select as_of_date, platform, invoice_number, tds_amount from gold.payment_status where tds_amount is not null$q$),
    ('metric_amount_payable', $q$select as_of_date, platform, invoice_number, amount_payable from gold.payment_status where amount_payable is not null$q$),
    ('metric_advance_paid', $q$select as_of_date, platform, invoice_number, advance_paid from gold.payment_status where advance_paid is not null$q$),
    ('metric_payment_amount', $q$select as_of_date, platform, invoice_number, payment_amount from gold.payment_status where payment_amount is not null$q$),
    -- 7
    ('metric_sales_contribution', $q$
       select s.sales_date, s.sidnl_id, s.platform, s.city_slug, round(100.0 * s.sales_mrp / nullif(b.bs, 0), 3)
       from _sales s join (select sales_date, platform, city_slug, brand_key, sum(sales_mrp) bs from _sales group by 1, 2, 3, 4) b
         using (sales_date, platform, city_slug, brand_key) where s.sales_mrp is not null$q$),
    ('metric_sales_impact', $q$
       select r.as_of_date, k.sidnl_id, r.platform, r.city_slug, round(sum(r.sales_impact_pct * r.sales_mrp) / nullif(sum(r.sales_mrp), 0), 3)
       from gold.rca_daily r join _pk k on k.product_key = r.product_key where r.sales_impact_pct is not null
       group by 1, 2, 3, 4$q$),
    -- 8
    ('metric_kw_vol', $q$select obs_date, platform, brand_key, keyword, city_slug, kw_volume_monthly from gold.keyword_perf where kw_volume_monthly is not null$q$),
    ('metric_overall_sov', $q$select obs_date, platform, category_l1_id, category_l2_id, city_slug, sidnl_id,
                                case when brands >= 2 and m_imp > 0 then round(100.0 * imp / m_imp, 2) end from _sh$q$),
    ('metric_organic_sov', $q$select obs_date, platform, category_l1_id, category_l2_id, city_slug, sidnl_id,
                                case when brands >= 2 and m_org > 0 then round(100.0 * org / m_org, 2) end from _sh$q$),
    ('metric_paid_sov', $q$select obs_date, platform, category_l1_id, category_l2_id, city_slug, sidnl_id,
                             case when brands >= 2 and m_paid > 0 then round(100.0 * paid / m_paid, 2) end from _sh where m_paid > 0$q$),
    ('metric_top_of_search_sov', $q$select obs_date, platform, category_l1_id, category_l2_id, city_slug, sidnl_id,
                                      case when brands >= 2 and m_top > 0 then round(100.0 * top / m_top, 2) end from _sh where m_top > 0$q$),
    ('metric_top_of_search_organic_sov', $q$select obs_date, platform, category_l1_id, category_l2_id, city_slug, sidnl_id,
                                      case when brands >= 2 and m_top_org > 0 then round(100.0 * top_org / m_top_org, 2) end from _sh where m_top_org > 0$q$),
    ('metric_top_of_search_paid_sov', $q$select obs_date, platform, category_l1_id, category_l2_id, city_slug, sidnl_id,
                                      case when brands >= 2 and m_top_paid > 0 then round(100.0 * top_paid / m_top_paid, 2) end from _sh where m_top_paid > 0$q$),
    ('metric_category_impression_share', $q$select obs_date, platform, category_l1_id, category_l2_id, city_slug, sidnl_id,
                                      round(100.0 * imp / nullif(m_imp, 0), 2) from _sh$q$),
    ('metric_competitor_market_share', $q$
       select c.obs_date, c.platform, c.city_slug, c.brand_key, c.category_l1_id, c.category_l2_id, c.market_share_pct
       from gold.competitor_daily c join gold.dim_brand b on b.brand_key = c.brand_key and not b.is_client
       where c.market_share_pct is not null$q$),
    ('metric_competitor_discount_pct', $q$
       select s.obs_date, s.platform, s.category_l1_id, s.category_l2_id, s.city_slug, s.sidnl_id, round(100.0 * s.sum_disc / s.sum_mrp, 2)
       from gold_stage.shelf_sidnl_daily s join gold.dim_brand b on b.brand_key = s.brand_key and not b.is_client
       where s.sum_mrp > 0$q$),
    ('metric_competitor_avg_sp', $q$
       select s.obs_date, s.platform, s.category_l1_id, s.category_l2_id, s.city_slug, s.sidnl_id, round(s.sum_sp / s.n_sp, 2)
       from gold_stage.shelf_sidnl_daily s join gold.dim_brand b on b.brand_key = s.brand_key and not b.is_client
       where s.n_sp > 0$q$),
    ('metric_ad_spend', $q$select obs_date, platform, brand_key, keyword, city_slug, ad_spend from gold.keyword_perf where ad_spend is not null$q$),
    ('metric_top_cities_skus', $q$
       with sb as (select sidnl_id, max(brand_key) brand_key from _pk group by 1),
       lst as (select l.as_of_date, k.sidnl_id, l.platform, l.city_slug, sum(l.listing_stores) a, sum(l.eligible_stores) e
               from gold.listing_snapshot l join _pk k on k.product_key = l.product_key
               where l.as_of_date = (select max(as_of_date) from gold.listing_snapshot) group by 1, 2, 3, 4),
       o as (select o.*, sb.brand_key from _osa o join sb using (sidnl_id) where o.platform <> 'ALL'
             and o.obs_date = (select max(obs_date) from _osa x where x.platform = o.platform)),
       l as (select lst.*, sb.brand_key from lst join sb using (sidnl_id)),
       i as (select s.*, sb.brand_key b2 from gold_stage.shelf_sidnl_daily s join sb using (sidnl_id)
             where s.city_slug = 'ALL' and s.obs_date = (select max(obs_date) from gold_stage.shelf_sidnl_daily x where x.platform = s.platform)),
       u as (
         select max(obs_date) d, platform, brand_key, 'city' dim, 'osa_pct' m, city_slug mem, round(100.0 * sum(a) / nullif(sum(e), 0), 3) v, sum(e) w
           from o where city_slug not in ('ALL', '(unknown)') group by platform, brand_key, city_slug
         union all
         select max(as_of_date), platform, brand_key, 'city', 'listing_pct', city_slug, round(100.0 * sum(a) / nullif(sum(e), 0), 3), sum(e)
           from l where city_slug not in ('ALL', '(unknown)') group by platform, brand_key, city_slug
         union all
         select obs_date, platform, brand_key, 'sku', 'osa_pct', sidnl_id, round(100.0 * a / nullif(e, 0), 3), e from o where city_slug = 'ALL'
         union all
         select as_of_date, platform, brand_key, 'sku', 'listing_pct', sidnl_id, round(100.0 * a / nullif(e, 0), 3), e from l where city_slug = 'ALL'
         union all
         select max(obs_date), platform, b2, 'sku', 'impressions', sidnl_id, sum(imp), sum(imp) from i group by platform, b2, sidnl_id)
       select d, platform, brand_key, dim, m, rk, mem, v
       from (select u.*, row_number() over (partition by platform, brand_key, dim, m order by v desc, w desc, mem) rk
             from u where v is not null and brand_key is not null) q
       where rk <= 10$q$),
    -- 9
    ('metric_mrp', $q$select obs_date, sidnl_id, platform, city_slug, mrp from _price where mrp is not null$q$),
    ('metric_sp', $q$select obs_date, sidnl_id, platform, city_slug, sp from _price where sp is not null$q$),
    ('metric_price_diff', $q$
       select a.obs_date, a.sidnl_id, a.platform, a.city_slug, a.sp - r.sp
       from _price a cross join _cfg c
       join _price r on r.obs_date = a.obs_date and r.sidnl_id = a.sidnl_id and r.city_slug = a.city_slug and r.platform = c.refplat
       where a.platform not in ('ALL', c.refplat) and a.sp is not null and r.sp is not null$q$),
    ('metric_price_diff_pct', $q$
       select a.obs_date, a.sidnl_id, a.platform, a.city_slug, round(100.0 * (a.sp - r.sp) / r.sp, 2)
       from _price a cross join _cfg c
       join _price r on r.obs_date = a.obs_date and r.sidnl_id = a.sidnl_id and r.city_slug = a.city_slug and r.platform = c.refplat
       where a.platform not in ('ALL', c.refplat) and r.sp > 0$q$),
    ('metric_threshold_diff', $q$
       select p.obs_date, k.sidnl_id, p.platform, p.city_slug, round(avg(p.city_avg_sp) - max(p.threshold_sp), 2)
       from gold.price_parity_city p join _pk k on k.product_key = p.product_key where p.threshold_sp is not null
       group by p.obs_date, k.sidnl_id, p.platform, p.city_slug$q$)
  ) j(tbl, q)
  loop
    v_stats := v_stats || jsonb_build_object(v_job.tbl, gold_stage.reload(v_job.tbl, v_job.q));
  end loop;

  update gold_stage.metric_registry r
     set row_count = (v_stats ->> r.metric_table)::bigint, last_refreshed_at = now(),
         status = coalesce((select c.status from gold.metric_catalog c where c.metric_key = r.catalog_key), r.status)
   where v_stats ? r.metric_table;

  insert into gold_stage.refresh_state (key, value) values ('last_stats', v_stats::text)
    on conflict (key) do update set value = excluded.value, updated_at = now();
  return v_stats;
end
$function$;

-- ------------------------------------------------ scheduler hook (replaces 101)
create or replace function silver.run_gold_pending()
 returns jsonb
 language plpgsql
 set search_path to 'silver', 'ops', 'public', 'gold', 'pg_temp'
 set statement_timeout to '600s'
as $function$
declare v record; v_t timestamptz; v_att int; v_metrics text := 'success';
begin
    if not pg_try_advisory_xact_lock(727101) then
        return jsonb_build_object('status', 'skipped', 'reason', 'gold refresh in progress');
    end if;
    select run_id, gold_status, gold_attempts into v from ops.pipeline_run
     where status = 'success' and (gold_status = 'pending' or (gold_status = 'failed' and gold_next_at <= now()))
     order by run_id desc limit 1;
    if not found then return jsonb_build_object('status', 'idle'); end if;
    update ops.pipeline_run set gold_status = 'superseded'
     where status = 'success' and gold_status = 'pending' and run_id < v.run_id;
    v_t := clock_timestamp();
    begin
        perform gold.refresh_all();
        begin
            perform gold_stage.refresh_metrics();
            delete from gold_stage.refresh_state where key = 'last_error';
        exception when others then
            v_metrics := 'failed';
            insert into gold_stage.refresh_state (key, value) values ('last_error', left(sqlerrm, 1000))
            on conflict (key) do update set value = excluded.value, updated_at = now();
        end;
        update ops.pipeline_run set gold_status = 'success', gold_error = null, gold_next_at = null,
               gold_seconds = round(extract(epoch from clock_timestamp() - v_t)::numeric, 2) where run_id = v.run_id;
        return jsonb_build_object('status', 'success', 'run_id', v.run_id, 'metrics', v_metrics);
    exception when others then
        v_att := v.gold_attempts + 1;
        update ops.pipeline_run
           set gold_status = 'failed', gold_error = left(sqlerrm, 1000), gold_attempts = v_att,
               gold_seconds = round(extract(epoch from clock_timestamp() - v_t)::numeric, 2),
               gold_next_at = case when v_att < 5 and silver.classify_error(sqlstate) = 'transient'
                                   then now() + make_interval(mins => silver.backoff_minutes(v_att)) end
         where run_id = v.run_id;
        return jsonb_build_object('status', 'failed', 'run_id', v.run_id, 'error', sqlerrm, 'attempt', v_att);
    end;
end $function$;
