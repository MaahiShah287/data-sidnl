import KpiCard from '@/components/KpiCard';
import Header, { Empty } from '@/components/Header';
import { Trend } from '@/components/Charts';
import { q, pct, n, osaColor } from '@/lib/db';

export const dynamic = 'force-dynamic';

export default async function OverviewPage() {
  const [[a], [p], [v], [ov, ads, sup], trend, plat] = await Promise.all([
    q(`with d as (select max(obs_date) dt from dash.availability where store_key is null)
       select dt::text, sum(osa_available_obs)::float8/nullif(sum(osa_eligible_obs),0)*100 osa,
              sum(ds_listed_stores)::float8/nullif(sum(ds_eligible_stores),0)*100 ds_listing,
              count(distinct sidnl_id) skus,
              count(*) filter (where out_of_stock_stores > 0) oos_rows
         from dash.availability, d where store_key is null and obs_date = d.dt group by dt`),
    q(`with d as (select max(obs_date) dt from dash.pricing)
       select dt::text, avg(selling_price)::float8 asp, avg(weighted_discount_pct)::float8 disc,
              count(*) filter (where is_parity_break) parity_breaks
         from dash.pricing, d where obs_date = d.dt group by dt`),
    q(`with d as (select max(obs_date) dt from dash.visibility where search_type='category')
       select dt::text, count(distinct search_term) markets, avg(avg_search_rank)::float8 rank
         from dash.visibility, d where search_type='category' and obs_date = d.dt group by dt`),
    q(`select (select count(*) from dash.overview) ov, (select count(*) from dash.ads) ads, (select count(*) from dash.supply) sup`)
      .then(r => [r[0].ov, r[0].ads, r[0].sup]),
    q(`select obs_date::text d, platform,
              round((sum(osa_available_obs)::float8/nullif(sum(osa_eligible_obs),0)*100)::numeric,1)::float8 osa
         from dash.availability where store_key is null group by 1,2 order by 1`),
    q(`with d as (select max(obs_date) dt from dash.availability where store_key is null)
       select platform, sum(osa_available_obs)::float8/nullif(sum(osa_eligible_obs),0)*100 osa,
              sum(ds_listed_stores)::float8/nullif(sum(ds_eligible_stores),0)*100 ds_listing,
              count(distinct sidnl_id) skus, count(distinct city_slug) cities
         from dash.availability, d where store_key is null and obs_date = d.dt group by 1 order by 4 desc`),
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
        <Trend data={chart} x="d" series={platforms} />
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
        {Number(ov) === 0 && <Empty what="Sales (GMV, net sales, units, market share): waiting for a sales feed." />}
        {Number(ads) === 0 && <Empty what="Ads (spend, ROAS, campaigns): waiting for a retail-media feed." />}
        {Number(sup) === 0 && <Empty what="Supply (POs, invoices, EDI): waiting for a vendor-portal / ERP feed." />}
      </div>
    </div>
  );
}
