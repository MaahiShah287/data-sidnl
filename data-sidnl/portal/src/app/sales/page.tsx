import KpiCard from '@/components/KpiCard';
import Header, { Empty } from '@/components/Header';
import { Trend } from '@/components/Charts';
import { qSafe, inr, num, pct, n } from '@/lib/db';

export const dynamic = 'force-dynamic';

// First-party sales (Zepto seller-portal SALES_OVERVIEW + PRODUCT_PERFORMANCE exports) -> dash.v_fp_sales_* views.
// GMV here is gross (before discounts / refunds): the export has no net-sales, refund or target columns, so those
// KPIs are shown as unavailable. Stock on hand is one national snapshot (no city / batch split).
export default async function SalesPage() {
  const [h, month, day, city, sku] = await Promise.all([
    qSafe(`select as_of::text, first_date::text, gmv_total::float8, units_total::float8, asp_total::float8,
                  gmv_28d::float8, units_28d::float8, asp_28d::float8, gmv_prev_28d::float8, units_prev_28d::float8,
                  gmv_growth_pct::float8, units_growth_pct::float8 from dash.v_fp_sales_health limit 1`),
    qSafe(`select month::text m, gmv::float8, units::float8, asp::float8, days_with_data from dash.v_fp_sales_month order by month`),
    qSafe(`select sales_date::text d, gmv::float8, units::float8 from dash.v_fp_sales_day
            where sales_date > (select max(sales_date) from dash.v_fp_sales_day) - 60 order by sales_date`),
    qSafe(`select city, gmv_total::float8, units_total::float8, contribution_pct_total::float8 share_total,
                  gmv_28d::float8, units_28d::float8, contribution_pct_28d::float8 share_28d, gmv_prev_28d::float8, growth_pct::float8
             from dash.v_fp_sales_city order by gmv_28d desc, gmv_total desc limit 25`),
    qSafe(`select product_name, gmv_total::float8, units_total::float8, asp::float8, gmv_28d::float8, units_28d::float8,
                  avg_daily_units_28d::float8 daily, last_sale::text, days_since_last_sale, stock_on_hand, doi_days::float8,
                  landing_cost::float8, stock_value_at_cost::float8, not_selling
             from dash.v_fp_sales_sku order by gmv_total desc`),
  ]);

  const k = h.rows[0];
  const err = h.error ?? sku.error;
  const stockValue = sku.rows.reduce((s: number, r: any) => s + (r.stock_value_at_cost ?? 0), 0);
  const stockUnits = sku.rows.reduce((s: number, r: any) => s + (r.stock_on_hand ?? 0), 0);
  const notSelling = sku.rows.filter((r: any) => r.not_selling);

  return (
    <div className="space-y-6">
      <Header title="Sales" subtitle="GMV, units, ASP, city performance, stock cover (first-party Zepto seller-portal exports)" />
      {err && <Empty what={`Sales views could not be read: ${err.slice(0, 160)}. Apply sql/migrations/dash_016_fp_metric_views.sql.`} />}
      {!err && !k && <Empty what="No first-party sales loaded yet." />}

      {!err && k && (
        <>
          <p className="text-xs text-slate-500">
            Zepto · {k.first_date} → {k.as_of}. GMV is gross (before discounts and refunds). Not in the export, so shown as unavailable
            (never 0): net sales, refunds, sales targets.
          </p>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            <KpiCard title="GMV (all days)" value={inr(k.gmv_total)} subtitle="gross" />
            <KpiCard title="Units sold" value={num(k.units_total)} />
            <KpiCard title="ASP (gross)" value={inr(k.asp_total, 2)} subtitle="GMV ÷ units" />
            <KpiCard title="GMV last 28 days" value={inr(k.gmv_28d)}
              subtitle={k.gmv_growth_pct != null ? `${k.gmv_growth_pct > 0 ? '+' : ''}${n(k.gmv_growth_pct, 1)}% vs previous 28 days` : undefined}
              badge={k.gmv_growth_pct != null ? (k.gmv_growth_pct >= 0 ? 'growing' : 'declining') : undefined}
              badgeColor={k.gmv_growth_pct != null ? (k.gmv_growth_pct >= 0 ? 'green' : 'red') : 'gray'} />
            <KpiCard title="Units last 28 days" value={num(k.units_28d)}
              subtitle={k.units_growth_pct != null ? `${k.units_growth_pct > 0 ? '+' : ''}${n(k.units_growth_pct, 1)}% vs previous 28 days` : undefined} />
            <KpiCard title="ASP last 28 days" value={inr(k.asp_28d, 2)} />
            <KpiCard title="Net sales / refunds" value={null} unavailable />
            <KpiCard title="Target achievement" value={null} unavailable subtitle="no targets loaded" />
          </div>

          <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
              <h2 className="section-title">GMV by month (₹)</h2>
              <Trend data={month.rows} x="m" series={['gmv']} suffix="" />
              <table className="data-table mt-3">
                <thead><tr><th>Month</th><th>GMV</th><th>Units</th><th>ASP</th><th>Days</th></tr></thead>
                <tbody>{month.rows.map((r: any) => (
                  <tr key={r.m}><td>{r.m.slice(0, 7)}</td><td>{inr(r.gmv)}</td><td>{num(r.units)}</td><td>{inr(r.asp, 2)}</td><td>{r.days_with_data}</td></tr>))}</tbody>
              </table>
            </div>
            <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
              <h2 className="section-title">Daily GMV and units (last 60 days)</h2>
              <Trend data={day.rows} x="d" series={['gmv']} suffix="" />
              <Trend data={day.rows} x="d" series={['units']} suffix="" />
            </div>
          </div>

          <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
            <h2 className="section-title">City performance (share of GMV, growth vs previous 28 days)</h2>
            <div className="overflow-auto max-h-96"><table className="data-table">
              <thead><tr><th>City</th><th>GMV 28d</th><th>Share 28d</th><th>Growth</th><th>GMV all days</th><th>Share all days</th><th>Units 28d</th></tr></thead>
              <tbody>{city.rows.map((r: any) => (
                <tr key={r.city}><td>{r.city}</td><td>{inr(r.gmv_28d)}</td><td>{pct(r.share_28d, 1)}</td>
                  <td>{r.growth_pct == null ? '—' : `${r.growth_pct > 0 ? '+' : ''}${n(r.growth_pct, 1)}%`}</td>
                  <td>{inr(r.gmv_total)}</td><td>{pct(r.share_total, 1)}</td><td>{num(r.units_28d)}</td></tr>))}</tbody>
            </table></div>
            <p className="text-xs text-slate-400 mt-2">Top 25 cities by last-28-day GMV. Shares are of the brand total; growth is shown only where the previous 28 days had sales.</p>
          </div>

          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            <KpiCard title="Stock on hand" value={num(stockUnits)} subtitle="units, national snapshot" />
            <KpiCard title="Stock value at cost" value={inr(stockValue)} subtitle="stock × latest landing cost" />
            <KpiCard title="SKUs not selling" value={notSelling.length} subtitle="stock > 0, no sales in 28 days"
              badge={notSelling.length ? 'review' : undefined} badgeColor="yellow" />
            <KpiCard title="Stock by city / batch / expiry" value={null} unavailable />
          </div>

          <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
            <h2 className="section-title">SKU sales, stock cover and stock value</h2>
            <div className="overflow-auto"><table className="data-table">
              <thead><tr><th>SKU</th><th>GMV</th><th>Units</th><th>ASP</th><th>Units 28d</th><th>Avg / day</th><th>Last sale</th>
                <th>Stock</th><th>Days of inventory</th><th>Landing cost</th><th>Stock value</th></tr></thead>
              <tbody>{sku.rows.map((r: any) => (
                <tr key={r.product_name}><td className="max-w-xs truncate" title={r.product_name}>{r.product_name}{r.not_selling && <span className="ml-1 badge badge-yellow">not selling</span>}</td>
                  <td>{inr(r.gmv_total)}</td><td>{num(r.units_total)}</td><td>{inr(r.asp, 2)}</td><td>{num(r.units_28d)}</td>
                  <td>{n(r.daily, 1)}</td><td>{r.last_sale ?? 'never'}</td><td>{num(r.stock_on_hand)}</td>
                  <td>{r.doi_days == null ? '—' : `${n(r.doi_days, 0)} d`}</td><td>{inr(r.landing_cost, 2)}</td><td>{inr(r.stock_value_at_cost)}</td></tr>))}</tbody>
            </table></div>
            <p className="text-xs text-slate-400 mt-2">
              Days of inventory = national stock on hand ÷ average daily units over the last 28 days. Shown as — when there were no sales
              (never divided by zero). Landing cost is the latest cost on a goods receipt.
            </p>
          </div>
        </>
      )}
    </div>
  );
}
