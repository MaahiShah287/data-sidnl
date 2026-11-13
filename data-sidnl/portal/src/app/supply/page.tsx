import KpiCard from '@/components/KpiCard';
import Header, { Empty } from '@/components/Header';
import { Trend } from '@/components/Charts';
import { qSafe, inr, num, pct, n } from '@/lib/db';

export const dynamic = 'force-dynamic';

// Purchase orders and goods receipts (Zepto GRN + PO exports) -> dash.v_fp_po_* views.
// The GRN export omits a PO line that was never received; v_fp_po_line_all adds those lines back from the PO export
// (received = 0), so unreceived quantity counts as shortfall in the fill rate.
// PO value = ordered qty x landing cost. Fill rate = sum(received) / sum(ordered) (never an average of POs).
export default async function SupplyPage() {
  const [t, month, status, sku, pos, fr] = await Promise.all([
    qSafe(`select count(*)::int pos, sum(lines)::int lines, sum(po_qty)::float8 po_qty, sum(asn_qty)::float8 asn_qty, sum(grn_qty)::float8 grn_qty,
                  sum(po_value)::float8 po_value, sum(grn_value)::float8 grn_value,
                  (100.0 * sum(grn_qty) / nullif(sum(po_qty), 0))::float8 fill_rate,
                  (100.0 * sum(asn_qty) / nullif(sum(po_qty), 0))::float8 asn_rate,
                  count(*) filter (where fully_received)::int full_pos, count(*) filter (where partially_received)::int partial_pos,
                  (percentile_cont(0.5) within group (order by lead_days))::float8 median_lead,
                  (percentile_cont(0.5) within group (order by days_after_po_delivery_date))::float8 median_after_delivery,
                  (100.0 * count(*) filter (where days_after_po_delivery_date <= 0) / nullif(count(*) filter (where days_after_po_delivery_date is not null), 0))::float8 pct_by_delivery_date,
                  min(po_date)::text d0, max(po_date)::text d1,
                  (select count(*) from dash.v_fp_po_line_all where source = 'po_only')::int unreceived_lines
             from dash.v_fp_po_summary`),
    qSafe(`select month::text m, pos, po_qty::float8, grn_qty::float8, po_value::float8, grn_value::float8, fill_rate_pct::float8 fill from dash.v_fp_po_month order by month`),
    qSafe(`select po_status, pos, po_qty::float8, grn_qty::float8, fill_rate_pct::float8 fill from dash.v_fp_po_status order by pos desc`),
    qSafe(`select product_name, pos, po_qty::float8, asn_qty::float8, grn_qty::float8, open_qty::float8, fill_rate_pct::float8 fill, po_value::float8, grn_value::float8, vendors
             from dash.v_fp_po_sku order by po_value desc`),
    qSafe(`select po_code, po_date::text, po_status, store, lines, po_qty::float8, grn_qty::float8, shortfall_qty::float8, fill_rate_pct::float8 fill,
                  po_value::float8, grn_value::float8, po_delivery_date::text, first_grn_date::text, days_after_po_delivery_date dad, lead_days
             from dash.v_fp_po_summary order by po_date desc, po_code desc limit 40`),
    qSafe(`select week_no, date_from::text d0, date_to::text d1, city, quantity_fill_rate::float8 qfr, line_fill_rate::float8 lfr
             from dash.fp_fill_rate where date_from >= (select max(date_from) from dash.fp_fill_rate) - 21 order by date_from desc, city`),
  ]);

  const k = t.rows[0];
  const err = t.error;

  return (
    <div className="space-y-6">
      <Header title="Supply" subtitle="Purchase orders, goods receipts, fill rate, lead time (first-party Zepto exports)" />
      {err && <Empty what={`PO views could not be read: ${err.slice(0, 160)}. Apply sql/migrations/dash_016_fp_metric_views.sql.`} />}
      {!err && (!k || !k.pos) && <Empty what="No goods-receipt data loaded yet." />}

      {!err && k && k.pos > 0 && (
        <>
          <div className="bg-amber-50 border border-amber-200 rounded-lg p-3 text-xs text-amber-800 space-y-1">
            <p>{k.pos} POs created {k.d0} → {k.d1}. Every PO in the export has a status of <b>Expired</b> or <b>Locked</b>; there are no open or
               pending POs, so open-PO and acceptance metrics are not shown.</p>
            <p>The GRN export does not state a committed delivery date, so on-time delivery is <b>not asserted</b>. The timing card below
               compares the first receipt with the PO delivery date on the PO, which is the only date available; confirm the definition with the
               supply owner before treating it as on-time.</p>
          </div>

          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            <KpiCard title="Purchase orders" value={num(k.pos)} subtitle={`${num(k.lines)} PO × SKU lines`} />
            <KpiCard title="PO value" value={inr(k.po_value)} subtitle="ordered qty × landing cost" />
            <KpiCard title="GRN value" value={inr(k.grn_value)} subtitle="received qty × landing cost" />
            <KpiCard title="Quantity fill rate" value={pct(k.fill_rate, 2)} subtitle={`${num(k.grn_qty)} received of ${num(k.po_qty)} ordered`} />
            <KpiCard title="Shortfall" value={num(k.po_qty - k.grn_qty)} subtitle="units ordered, never received" />
            <KpiCard title="Fully received POs" value={`${num(k.full_pos)} of ${num(k.pos)}`} subtitle={`${num(k.partial_pos)} partially received`} />
            <KpiCard title="Median lead time" value={k.median_lead == null ? null : `${n(k.median_lead, 0)} days`} subtitle="PO date → first receipt" />
            <KpiCard title="Median days after PO delivery date" value={k.median_after_delivery == null ? null : `${n(k.median_after_delivery, 0)} days`}
              subtitle={`${pct(k.pct_by_delivery_date, 0)} received on or before it`} />
          </div>
          {k.unreceived_lines > 0 && (
            <p className="text-xs text-slate-500">{k.unreceived_lines} ordered line(s) have no goods receipt at all and are counted as fully short.</p>
          )}

          <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
              <h2 className="section-title">PO volume and value by month</h2>
              <Trend data={month.rows} x="m" series={['po_value', 'grn_value']} suffix="" />
              <table className="data-table mt-3">
                <thead><tr><th>Month</th><th>POs</th><th>Ordered</th><th>Received</th><th>Fill rate</th><th>PO value</th></tr></thead>
                <tbody>{month.rows.map((r: any) => (
                  <tr key={r.m}><td>{r.m.slice(0, 7)}</td><td>{r.pos}</td><td>{num(r.po_qty)}</td><td>{num(r.grn_qty)}</td><td>{pct(r.fill, 2)}</td><td>{inr(r.po_value)}</td></tr>))}</tbody>
              </table>
            </div>
            <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
              <h2 className="section-title">PO status distribution</h2>
              <table className="data-table">
                <thead><tr><th>Status</th><th>POs</th><th>Share</th><th>Ordered</th><th>Received</th><th>Fill rate</th></tr></thead>
                <tbody>{status.rows.map((r: any) => (
                  <tr key={r.po_status}><td>{r.po_status}</td><td>{r.pos}</td><td>{pct(100 * r.pos / k.pos, 0)}</td><td>{num(r.po_qty)}</td><td>{num(r.grn_qty)}</td><td>{pct(r.fill, 2)}</td></tr>))}</tbody>
              </table>
              <h2 className="section-title mt-6">Zepto-reported fill rate by city (latest weeks)</h2>
              {fr.rows.length === 0 ? <Empty what="No fill-rate rows." /> : (
                <div className="overflow-auto max-h-64"><table className="data-table">
                  <thead><tr><th>Week</th><th>City</th><th>Quantity</th><th>Line</th></tr></thead>
                  <tbody>{fr.rows.map((r: any) => (
                    <tr key={`${r.d0}-${r.city}`}><td>W{r.week_no} ({r.d0.slice(5)}→{r.d1.slice(5)})</td><td>{r.city}</td><td>{pct(r.qfr, 2)}</td><td>{pct(r.lfr, 1)}</td></tr>))}</tbody>
                </table></div>
              )}
              <p className="text-xs text-slate-400 mt-2">Shown as reported (no order counts in the file, so these are not averaged across cities or weeks).</p>
            </div>
          </div>

          <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
            <h2 className="section-title">SKU view (ordered vs delivered)</h2>
            <div className="overflow-auto"><table className="data-table">
              <thead><tr><th>SKU</th><th>POs</th><th>Ordered</th><th>ASN</th><th>Received</th><th>Open qty</th><th>Fill rate</th><th>PO value</th><th>GRN value</th><th>Suppliers</th></tr></thead>
              <tbody>{sku.rows.map((r: any) => (
                <tr key={r.product_name}><td className="max-w-xs truncate" title={r.product_name}>{r.product_name}</td><td>{r.pos}</td><td>{num(r.po_qty)}</td>
                  <td>{num(r.asn_qty)}</td><td>{num(r.grn_qty)}</td><td>{num(r.open_qty)}</td><td>{pct(r.fill, 2)}</td><td>{inr(r.po_value)}</td><td>{inr(r.grn_value)}</td><td>{r.vendors}</td></tr>))}</tbody>
            </table></div>
          </div>

          <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
            <h2 className="section-title">Latest purchase orders</h2>
            <div className="overflow-auto max-h-96"><table className="data-table">
              <thead><tr><th>PO</th><th>Date</th><th>Status</th><th>Store</th><th>Lines</th><th>Ordered</th><th>Received</th><th>Short</th><th>Fill</th><th>PO value</th><th>First receipt</th><th>Lead</th><th>After PO delivery date</th></tr></thead>
              <tbody>{pos.rows.map((r: any) => (
                <tr key={r.po_code}><td>{r.po_code}</td><td>{r.po_date}</td><td>{r.po_status}</td><td>{r.store}</td><td>{r.lines}</td><td>{num(r.po_qty)}</td>
                  <td>{num(r.grn_qty)}</td><td>{num(r.shortfall_qty)}</td><td>{pct(r.fill, 1)}</td><td>{inr(r.po_value)}</td><td>{r.first_grn_date ?? '—'}</td>
                  <td>{r.lead_days == null ? '—' : `${r.lead_days} d`}</td><td>{r.dad == null ? '—' : `${r.dad} d`}</td></tr>))}</tbody>
            </table></div>
            <p className="text-xs text-slate-400 mt-2">Latest 40 of {k.pos} POs. Marketplace-wise fulfilment is not split: every PO is Zepto.</p>
          </div>
        </>
      )}
    </div>
  );
}
