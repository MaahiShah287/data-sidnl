import KpiCard from '@/components/KpiCard';
import Header, { Empty } from '@/components/Header';
import FilterBar from '@/components/FilterBar';
import { Trend } from '@/components/Charts';
import { q, pct, n, osaColor, SP, pickPlatform, pickBrand, fP, fB, clientBrands } from '@/lib/db';
import Link from 'next/link';

export const dynamic = 'force-dynamic';

export default async function OverviewPage({ searchParams }: { searchParams?: SP }) {
  const pf = pickPlatform(searchParams);
  const bk = pickBrand(searchParams);
  const args = [pf, bk];
  const F0 = `${fP()} and ${fB()}`;
  const P0 = fP();

  const [[a], [p], [v], [ov, ads, sup], trend, plat, brands] = await Promise.all([
    q(`with d as (select max(obs_date) dt from dash.availability where store_key is null and ${F0})
       select dt::text, sum(osa_available_obs)::float8/nullif(sum(osa_eligible_obs),0)*100 osa,
              sum(ds_listed_stores)::float8/nullif(sum(ds_eligible_stores),0)*100 ds_listing,
              count(distinct sidnl_id) skus,
              count(*) filter (where out_of_stock_stores > 0) oos_rows
         from dash.availability, d where store_key is null and obs_date = d.dt and ${F0} group by dt`, args),
    q(`with d as (select max(obs_date) dt from dash.pricing where ${F0})
       select dt::text, avg(selling_price)::float8 asp, avg(weighted_discount_pct)::float8 disc,
              count(*) filter (where is_parity_break) parity_breaks
         from dash.pricing, d where obs_date = d.dt and ${F0} group by dt`, args),
    q(`with d as (select max(obs_date) dt from dash.visibility where search_type='category' and ${P0})
       select dt::text, count(distinct search_term) markets, avg(avg_search_rank)::float8 rank
         from dash.visibility, d where search_type='category' and obs_date = d.dt and ${P0} group by dt`, [pf]),
    // first-party feeds (dash.v_fp_* views); never let a missing view take the whole Overview down
    q(`select (select count(*) from dash.v_fp_sales_day) ov, (select count(*) from dash.v_fp_ad_page) ads, (select count(*) from dash.v_fp_po_summary) sup`)
      .then(r => [r[0].ov, r[0].ads, r[0].sup])
      .catch(() => [0, 0, 0]),
    q(`select obs_date::text d, platform,
              round((sum(osa_available_obs)::float8/nullif(sum(osa_eligible_obs),0)*100)::numeric,1)::float8 osa
         from dash.availability where store_key is null and ${F0} group by 1,2 order by 1`, args),
    q(`with d as (select max(obs_date) dt from dash.availability where store_key is null and ${F0})
       select platform, sum(osa_available_obs)::float8/nullif(sum(osa_eligible_obs),0)*100 osa,
              sum(ds_listed_stores)::float8/nullif(sum(ds_eligible_stores),0)*100 ds_listing,
              count(distinct sidnl_id) skus, count(distinct city_slug) cities
         from dash.availability, d where store_key is null and obs_date = d.dt and ${F0} group by 1 order by 4 desc`, args),
    clientBrands(),
  ]);

  const days = Array.from(new Set(trend.map((r: any) => r.d)));
  const platforms = Array.from(new Set(trend.map((r: any) => r.platform))) as string[];
  const chart = days.map(d => {
    const row: any = { d };
    trend.filter((r: any) => r.d === d).forEach((r: any) => (row[r.platform] = r.osa));
    return row;
  });

  return (
    <div className="space-y-6">
      <Header title="Overview" subtitle="Live from silver → dash, refreshed after every pipeline run" />
      <FilterBar base="/" platform={pf} brand={bk} brands={brands} />

      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <KpiCard title="OSA %" value={pct(a?.osa)} subtitle={`as of ${a?.dt ?? '—'}`} />
        <KpiCard title="DS listing %" value={pct(a?.ds_listing)} />
        <KpiCard title="SKUs tracked" value={a?.skus ?? '—'} subtitle={`${a?.oos_rows ?? 0} SKU-cities with stock-outs`} />
        <KpiCard title="Avg selling price" value={p?.asp != null ? `₹${n(p.asp)}` : '—'} subtitle={`avg discount ${pct(p?.disc)}`} />
        <KpiCard title="Price parity breaks" value={p?.parity_breaks ?? '—'} />
        <KpiCard title="Search markets" value={v?.markets ?? '—'} subtitle={`avg rank ${n(v?.rank)}`} />
      </div>

      <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
        <h2 className="section-title">OSA % by day</h2>
        {chart.length ? <Trend data={chart} x="d" series={platforms} /> : <Empty what="No availability rows for this filter." />}
      </div>

      <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
        <h2 className="section-title">Marketplaces (latest day)</h2>
        <table className="data-table">
          <thead><tr><th>Platform</th><th>OSA %</th><th>DS listing %</th><th>SKUs</th><th>Cities</th></tr></thead>
          <tbody>
            {plat.map((r: any) => (
              <tr key={r.platform}>
                <td className="font-medium capitalize">{r.platform}</td>
                <td className={osaColor(r.osa)}>{pct(r.osa)}</td>
                <td>{pct(r.ds_listing)}</td><td>{r.skus}</td><td>{r.cities}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        {Number(ov) === 0 && <Empty what="Sales (GMV, units, ASP): no first-party sales loaded." />}
        {Number(ov) > 0 && (
          <div className="bg-white rounded-xl border border-slate-200 p-5 text-sm text-slate-600">
            Zepto first-party sales are live - <Link href="/sales" className="text-blue-600 underline">open Sales</Link> (GMV, units, ASP, city performance, stock cover).
          </div>
        )}
        {Number(ads) === 0 && <Empty what="Ads (spend, ROAS, CTR): no ad-console export loaded." />}
        {Number(ads) > 0 && (
          <div className="bg-white rounded-xl border border-slate-200 p-5 text-sm text-slate-600">
            Zepto ads (ad-console export, by page) are live - <Link href="/ads" className="text-blue-600 underline">open Ads</Link>.
            Keyword- and campaign-level ads need a keyword-level export.
          </div>
        )}
        {Number(sup) === 0 && <Empty what="Supply (POs, goods receipts, invoices): no first-party PO or invoice data loaded." />}
        {Number(sup) > 0 && (
          <div className="bg-white rounded-xl border border-slate-200 p-5 text-sm text-slate-600">
            Purchase orders, goods receipts and invoices are live - <Link href="/supply" className="text-blue-600 underline">Supply</Link> ·{' '}
            <Link href="/finance" className="text-blue-600 underline">Finance</Link>. EDI messages: waiting for an EDI gateway feed.
          </div>
        )}
      </div>
      <p className="text-xs text-slate-500">
        Which of the 171 handbook metrics are visible and which are not: <Link href="/metrics" className="text-blue-600 underline">Metric coverage</Link>.
      </p>
    </div>
  );
}
