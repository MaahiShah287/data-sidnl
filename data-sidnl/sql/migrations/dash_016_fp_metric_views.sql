-- dash_016_fp_metric_views.sql
-- Metric views over the first-party feeds loaded into dash.fp_* (Zepto seller-portal exports).
-- Conventions (docs/FRONTEND_QUERIES.md):
--   * ratios are always recomputed from additive columns (sum / sum), never averaged;
--   * every view carries brand_id so a workspace/brand filter can be applied later;
--   * nothing is estimated from scraped prices: sales, stock, PO, invoice and ad numbers come only from these feeds;
--   * "as of" = the latest date present in the feed, not today's date, so a stale export never looks current.
-- Idempotent (create or replace / enable RLS is repeatable). Rollback at the bottom of sql/rollbacks.sql.

-- 0. same posture as the other dash tables: RLS on, no policies (server-side pool reads only)
do $$
declare t text;
begin
  foreach t in array array['fp_sku','fp_sku_name','fp_sales_daily','fp_po','fp_po_line','fp_grn_line',
    'fp_ad_wallet_txn','fp_ad_page_perf','fp_fill_rate','fp_new_user_share','fp_invoice','fp_payment_advice',
    'fp_debit_credit_note','fp_ledger_entry','fp_product_snapshot','fp_load_log'] loop
    execute format('alter table dash.%I enable row level security', t);
    execute format('revoke all on dash.%I from anon, authenticated', t);
  end loop;
end $$;

-- 1. SALES (metrics 1 GMV, 3 Units, 4 ASP, 9 Sales health, 20 City performance) -----------------------------------
create or replace view dash.v_fp_sales_day as
select brand_id, sales_date, sum(gmv)::numeric(14,2) as gmv, sum(quantity)::bigint as units,
       round(sum(gmv) / nullif(sum(quantity), 0), 2) as asp,
       count(*) filter (where quantity > 0)::int as selling_rows
from dash.fp_sales_daily group by brand_id, sales_date;

create or replace view dash.v_fp_sales_month as
select brand_id, date_trunc('month', sales_date)::date as month, sum(gmv)::numeric(14,2) as gmv,
       sum(quantity)::bigint as units, round(sum(gmv) / nullif(sum(quantity), 0), 2) as asp,
       count(distinct sales_date)::int as days_with_data
from dash.fp_sales_daily group by brand_id, date_trunc('month', sales_date);

-- business health: last 28 days vs the 28 days before (anchored on the newest sales date)
create or replace view dash.v_fp_sales_health as
with mx as (select brand_id, max(sales_date) d, min(sales_date) d0 from dash.fp_sales_daily group by brand_id)
select s.brand_id, mx.d as as_of, mx.d0 as first_date,
  sum(s.gmv)::numeric(14,2) as gmv_total, sum(s.quantity)::bigint as units_total,
  round(sum(s.gmv) / nullif(sum(s.quantity), 0), 2) as asp_total,
  sum(s.gmv) filter (where s.sales_date > mx.d - 28)::numeric(14,2) as gmv_28d,
  sum(s.quantity) filter (where s.sales_date > mx.d - 28)::bigint as units_28d,
  round((sum(s.gmv) filter (where s.sales_date > mx.d - 28)) / nullif(sum(s.quantity) filter (where s.sales_date > mx.d - 28), 0), 2) as asp_28d,
  sum(s.gmv) filter (where s.sales_date > mx.d - 56 and s.sales_date <= mx.d - 28)::numeric(14,2) as gmv_prev_28d,
  sum(s.quantity) filter (where s.sales_date > mx.d - 56 and s.sales_date <= mx.d - 28)::bigint as units_prev_28d,
  round(100.0 * (sum(s.gmv) filter (where s.sales_date > mx.d - 28) - sum(s.gmv) filter (where s.sales_date > mx.d - 56 and s.sales_date <= mx.d - 28))
        / nullif(sum(s.gmv) filter (where s.sales_date > mx.d - 56 and s.sales_date <= mx.d - 28), 0), 1) as gmv_growth_pct,
  round(100.0 * (sum(s.quantity) filter (where s.sales_date > mx.d - 28) - sum(s.quantity) filter (where s.sales_date > mx.d - 56 and s.sales_date <= mx.d - 28))
        / nullif(sum(s.quantity) filter (where s.sales_date > mx.d - 56 and s.sales_date <= mx.d - 28), 0), 1) as units_growth_pct
from dash.fp_sales_daily s join mx on mx.brand_id = s.brand_id
group by s.brand_id, mx.d, mx.d0;

create or replace view dash.v_fp_sales_city as
with mx as (select brand_id, max(sales_date) d from dash.fp_sales_daily group by brand_id),
c as (
  select s.brand_id, s.city,
    sum(s.gmv) as gmv_total, sum(s.quantity) as units_total,
    sum(s.gmv) filter (where s.sales_date > mx.d - 28) as gmv_28d,
    sum(s.quantity) filter (where s.sales_date > mx.d - 28) as units_28d,
    sum(s.gmv) filter (where s.sales_date > mx.d - 56 and s.sales_date <= mx.d - 28) as gmv_prev_28d
  from dash.fp_sales_daily s join mx on mx.brand_id = s.brand_id group by s.brand_id, s.city)
select brand_id, city, gmv_total::numeric(14,2), units_total::bigint,
  round(100.0 * gmv_total / nullif(sum(gmv_total) over (partition by brand_id), 0), 2) as contribution_pct_total,
  coalesce(gmv_28d, 0)::numeric(14,2) as gmv_28d, coalesce(units_28d, 0)::bigint as units_28d,
  round(100.0 * gmv_28d / nullif(sum(gmv_28d) over (partition by brand_id), 0), 2) as contribution_pct_28d,
  coalesce(gmv_prev_28d, 0)::numeric(14,2) as gmv_prev_28d,
  round(100.0 * (gmv_28d - gmv_prev_28d) / nullif(gmv_prev_28d, 0), 1) as growth_pct
from c;

-- 2. STOCK / DOI / STOCK VALUE / NOT SELLING (metrics 25, 29, 53, 58) -------------------------------------------------
-- stock on hand comes from the portal's PRODUCT_PERFORMANCE export (national, one snapshot, no city/batch split)
create or replace view dash.v_fp_sku_stock as
with snap as (
  select distinct on (lower(regexp_replace(product_name, '\s+', ' ', 'g')))
         brand_id, lower(regexp_replace(product_name, '\s+', ' ', 'g')) as n, regexp_replace(product_name, '\s+', ' ', 'g') as product_name,
         stock_on_hand, available_stores_pct, snapshot_at
  from dash.fp_product_snapshot
  order by lower(regexp_replace(product_name, '\s+', ' ', 'g')), snapshot_at desc)
select distinct on (a.sku_id) a.sku_id, s.brand_id, s.product_name, s.stock_on_hand, s.available_stores_pct, s.snapshot_at
from dash.fp_sku_name a
join snap s on s.n = lower(regexp_replace(a.sku_name, '\s+', ' ', 'g'))
order by a.sku_id, s.snapshot_at desc;

create or replace view dash.v_fp_sku_cost as
select distinct on (sku_id) sku_id, cost_price as landing_cost, (grn_date at time zone 'UTC')::date as cost_date
from dash.fp_grn_line where cost_price is not null
order by sku_id, grn_date desc nulls last, po_created_at desc nulls last;

create or replace view dash.v_fp_sales_sku as
with mx as (select brand_id, max(sales_date) d from dash.fp_sales_daily group by brand_id),
a as (
  select s.brand_id, s.sku_id, mx.d as as_of,
    sum(s.gmv) as gmv_total, sum(s.quantity) as units_total,
    coalesce(sum(s.gmv) filter (where s.sales_date > mx.d - 28), 0) as gmv_28d,
    coalesce(sum(s.quantity) filter (where s.sales_date > mx.d - 28), 0) as units_28d,
    max(s.sales_date) filter (where s.quantity > 0) as last_sale
  from dash.fp_sales_daily s join mx on mx.brand_id = s.brand_id group by s.brand_id, s.sku_id, mx.d)
select a.brand_id, a.sku_id,
  coalesce(k.product_name, (select n.sku_name from dash.fp_sku_name n where n.sku_id = a.sku_id order by n.sku_name desc limit 1)) as product_name,
  a.gmv_total::numeric(14,2), coalesce(a.units_total, 0)::bigint as units_total,
  round(a.gmv_total / nullif(a.units_total, 0), 2) as asp,
  a.gmv_28d::numeric(14,2), a.units_28d::bigint,
  round(a.units_28d / 28.0, 2) as avg_daily_units_28d,
  a.last_sale, (a.as_of - a.last_sale) as days_since_last_sale,
  k.stock_on_hand, k.available_stores_pct,
  case when a.units_28d > 0 then round(k.stock_on_hand / (a.units_28d / 28.0), 1) end as doi_days,
  c.landing_cost, round(k.stock_on_hand * c.landing_cost, 2) as stock_value_at_cost,
  (a.units_28d = 0 and coalesce(k.stock_on_hand, 0) > 0) as not_selling
from a
left join dash.v_fp_sku_stock k on k.sku_id = a.sku_id
left join dash.v_fp_sku_cost c on c.sku_id = a.sku_id;

-- 3. PURCHASE ORDERS / GRN (metrics 12, 68, 69, 71, 74-80, 82-84) ----------------------------------------------------
-- The GRN export lists one row per PO x SKU x GRN, so a PO line that was NEVER received is missing from it. The PO export
-- lists every ordered line. v_fp_po_line_all = GRN lines + PO-export lines that have no GRN row (received qty 0), so
-- unreceived quantity is counted as shortfall instead of silently dropping out of the fill rate.
-- PO value = ordered qty x landing cost.
drop view if exists dash.v_fp_po_month, dash.v_fp_po_status, dash.v_fp_po_sku, dash.v_fp_po_summary, dash.v_fp_po_line_all;

create view dash.v_fp_po_line_all as
select g.brand_id, g.po_code, g.sku_id, g.product_name, g.vendor_code, g.vendor_name, g.to_store_name, g.po_status_desc,
  (g.po_created_at at time zone 'UTC')::date as po_date, (g.po_delivery_at at time zone 'UTC')::date as po_delivery_date,
  (g.po_expiry_at at time zone 'UTC')::date as po_expiry_date, (g.grn_date at time zone 'UTC')::date as grn_date,
  g.po_qty, g.asn_qty, g.grn_qty, g.cost_price, 'grn'::text as source
from dash.fp_grn_line g
union all
select l.brand_id, l.po_no, l.sku_id, l.sku_desc, h.vendor_code, h.vendor_name, h.del_location,
  (select max(g2.po_status_desc) from dash.fp_grn_line g2 where g2.po_code = l.po_no),
  h.po_date::date, null::date, h.po_expiry_at::date, null::date,
  l.qty, l.asn_qty, 0, l.landing_cost, 'po_only'::text
from dash.fp_po_line l
join dash.fp_po h on h.po_no = l.po_no
where not exists (select 1 from dash.fp_grn_line g where g.po_code = l.po_no and g.sku_id = l.sku_id);

create view dash.v_fp_po_summary as
select brand_id, po_code, min(po_date) as po_date,
  max(po_status_desc) as po_status, max(vendor_name) as vendor, max(to_store_name) as store,
  count(*)::int as lines,
  sum(po_qty)::bigint as po_qty, sum(asn_qty)::bigint as asn_qty, sum(grn_qty)::bigint as grn_qty,
  round(sum(po_qty * cost_price), 2) as po_value, round(sum(grn_qty * cost_price), 2) as grn_value,
  round(100.0 * sum(grn_qty) / nullif(sum(po_qty), 0), 2) as fill_rate_pct,
  (sum(po_qty) - sum(grn_qty))::bigint as shortfall_qty,
  (sum(grn_qty) >= sum(po_qty)) as fully_received,
  (sum(grn_qty) > 0 and sum(grn_qty) < sum(po_qty)) as partially_received,
  min(po_delivery_date) as po_delivery_date, min(grn_date) as first_grn_date, max(po_expiry_date) as po_expiry_date,
  (min(grn_date) - min(po_date)) as lead_days,
  (min(grn_date) - min(po_delivery_date)) as days_after_po_delivery_date
from dash.v_fp_po_line_all group by brand_id, po_code;

create view dash.v_fp_po_sku as
select brand_id, sku_id, max(product_name) as product_name, count(distinct po_code)::int as pos,
  sum(po_qty)::bigint as po_qty, sum(asn_qty)::bigint as asn_qty, sum(grn_qty)::bigint as grn_qty,
  (sum(po_qty) - sum(grn_qty))::bigint as open_qty,
  round(100.0 * sum(grn_qty) / nullif(sum(po_qty), 0), 2) as fill_rate_pct,
  round(sum(po_qty * cost_price), 2) as po_value, round(sum(grn_qty * cost_price), 2) as grn_value,
  count(distinct vendor_code)::int as vendors
from dash.v_fp_po_line_all group by brand_id, sku_id;

create view dash.v_fp_po_month as
select brand_id, date_trunc('month', po_date)::date as month, count(*)::int as pos, sum(po_qty)::bigint as po_qty,
  sum(grn_qty)::bigint as grn_qty, sum(po_value) as po_value, sum(grn_value) as grn_value,
  round(100.0 * sum(grn_qty) / nullif(sum(po_qty), 0), 2) as fill_rate_pct
from dash.v_fp_po_summary group by brand_id, date_trunc('month', po_date);

create view dash.v_fp_po_status as
select brand_id, po_status, count(*)::int as pos, sum(po_qty)::bigint as po_qty, sum(grn_qty)::bigint as grn_qty,
  round(100.0 * sum(grn_qty) / nullif(sum(po_qty), 0), 2) as fill_rate_pct, sum(po_value) as po_value
from dash.v_fp_po_summary group by brand_id, po_status;

-- 4. INVOICES / PAYMENTS / DEBIT NOTES (metrics 13, 85-88, 91-93, 95, 96) ----------------------------------------------
-- payment advice lists the supplier-side internal references (fp_invoice.internal_ref), not invoice numbers.
-- A quantity debit note is matched to its invoice by external_ref = invoice_no || '_QD'.
create or replace view dash.v_fp_invoice_recon as
with asof as (select max(posted_at)::date d from dash.fp_ledger_entry),
g as (select invoice_no, sum(asn_qty * cost_price) as asn_value, sum(grn_qty * cost_price) as grn_value,
             sum(asn_qty) as asn_qty, sum(grn_qty) as grn_qty
        from dash.fp_grn_line group by invoice_no),
qd as (select external_ref, sum(debit_amount) as amt from dash.fp_debit_credit_note group by external_ref),
pd as (select i.invoice_no from dash.fp_invoice i
        where exists (select 1 from dash.fp_payment_advice a where i.internal_ref = any (a.invoice_nos)))
select i.brand_id, i.invoice_no, i.internal_ref, i.po_no, i.status, i.booked_at::date as invoice_date,
  i.invoice_amount,
  round(g.asn_value, 2) as asn_value, round(g.grn_value, 2) as grn_expected_value,
  g.asn_qty::bigint, g.grn_qty::bigint,
  round(i.invoice_amount - g.asn_value, 2) as invoice_vs_asn_diff,
  round(i.invoice_amount - g.grn_value, 2) as invoice_vs_grn_diff,
  coalesce(qd.amt, 0) as qty_debit_note,
  (pd.invoice_no is not null) as is_paid,
  case when pd.invoice_no is not null then 0 else round(i.invoice_amount - coalesce(qd.amt, 0), 2) end as pending_amount,
  (asof.d - i.booked_at::date) as age_days,
  case when asof.d - i.booked_at::date <= 30 then '0-30' when asof.d - i.booked_at::date <= 60 then '31-60'
       when asof.d - i.booked_at::date <= 90 then '61-90' else '90+' end as age_bucket
from dash.fp_invoice i cross join asof
left join g on g.invoice_no = i.invoice_no
left join qd on qd.external_ref = i.invoice_no || '_QD'
left join pd on pd.invoice_no = i.invoice_no;

create or replace view dash.v_fp_debit_note_month as
select brand_id, date_trunc('month', posted_at)::date as month,
  case when external_ref like '%\_QD' then 'Quantity shortfall (per invoice)' else 'Brand-funded discount (RTV)' end as kind,
  count(*)::int as notes, sum(debit_amount)::numeric(14,2) as amount
from dash.fp_debit_credit_note group by brand_id, 2, 3;

create or replace view dash.v_fp_finance_summary as
select i.brand_id,
  (select count(*) from dash.fp_invoice)::int as invoices,
  (select sum(invoice_amount) from dash.fp_invoice) as invoice_value,
  (select sum(pending_amount) from dash.v_fp_invoice_recon) as pending_value,
  (select sum(net_payment) from dash.fp_payment_advice) as payments_received,
  (select count(*) from dash.fp_payment_advice)::int as payments,
  (select sum(debit_amount) from dash.fp_debit_credit_note) as debit_notes_value,
  (select sum(abs(invoice_vs_grn_diff)) from dash.v_fp_invoice_recon) as mismatch_vs_grn_abs,
  (select sum(abs(invoice_vs_asn_diff)) from dash.v_fp_invoice_recon) as mismatch_vs_asn_abs,
  (select running_balance from dash.fp_ledger_entry where entry_type = 'OPENING_BALANCE') as ledger_opening,
  (select running_balance from dash.fp_ledger_entry order by row_no desc limit 1) as ledger_closing,
  (select max(posted_at)::date from dash.fp_ledger_entry) as as_of
from (select distinct brand_id from dash.fp_invoice) i;

-- 5. ADS (Zepto, page level) (metrics 14, 18, 121-129, 132, 133) --------------------------------------------------------
-- the export has no dates and no campaign/keyword split: it is one snapshot by ad page. Ratios are recomputed from the
-- additive columns; the source ratio columns (cpc, cpm, roas) are not used.
create or replace view dash.v_fp_ad_page as
select brand_id, snapshot_label, page_name, impressions, clicks, atc, orders, revenue, spend,
  round(100.0 * clicks / nullif(impressions, 0), 3) as ctr_pct,
  round(spend / nullif(clicks, 0), 2) as cpc,
  round(1000.0 * spend / nullif(impressions, 0), 2) as cpm,
  round(100.0 * orders / nullif(clicks, 0), 2) as cvr_pct,
  round(revenue / nullif(spend, 0), 2) as roas,
  round(100.0 * spend / nullif(revenue, 0), 1) as acos_pct,
  same_skus, other_skus
from dash.fp_ad_page_perf;

create or replace view dash.v_fp_ad_wallet_day as
select brand_id, (created_at at time zone 'Asia/Kolkata')::date as day,
  sum(amount) filter (where txn_type = 'debit' and subtype like '%ad\_spends') as ad_spend,
  sum(amount) filter (where txn_type = 'credit' and subtype = 'postpaid_topup') as topup,
  sum(amount) filter (where txn_type = 'credit' and subtype = 'postpaid_incentive') as incentive,
  sum(amount) filter (where subtype like '%refund') as refunds
from dash.fp_ad_wallet_txn where status = 'processed' group by brand_id, 2;
