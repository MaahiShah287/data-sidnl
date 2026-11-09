import KpiCard from '@/components/KpiCard';
import Header, { Empty } from '@/components/Header';
import { HBar } from '@/components/Charts';
import { q, pct, n, osaColor } from '@/lib/db';

export const dynamic = 'force-dynamic';

export default async function AvailabilityPage() {
  const [dm, brands, cats, critical, dates] = await Promise.all([
    // D-0..D-3 = the latest four observation dates; OSA = SUM(available)/SUM(eligible)
    q(`with d as (select obs_date, row_number() over (order by obs_date desc) rn
                    from (select distinct obs_date from dash.availability where store_key is null) x)
       select a.platform, a.city_slug, c.city_name,
         max(case when d.rn=1 then osa end) d0, max(case when d.rn=2 then osa end) d1,
         max(case when d.rn=3 then osa end) d2, max(case when d.rn=4 then osa end) d3
       from (select obs_date, platform, city_slug,
                    sum(osa_available_obs)::float8/nullif(sum(osa_eligible_obs),0)*100 osa
               from dash.availability where store_key is null group by 1,2,3) a
       join d using (obs_date) left join dash.dim_city c using (city_slug)
       where d.rn <= 4 group by 1,2,3 order by 1, 2`),
    q(`with d as (select max(obs_date) dt from dash.availability where store_key is null)
       select s.brand_key brand, sum(a.osa_available_obs)::float8/nullif(sum(a.osa_eligible_obs),0)*100 osa,
              count(distinct a.sidnl_id) skus
         from dash.availability a join dash.dim_sidnl s using (sidnl_id), d
        where a.store_key is null and a.obs_date = d.dt
        group by 1 having sum(a.osa_eligible_obs) > 0 order by 2 desc limit 15`),
    q(`with d as (select max(obs_date) dt from dash.availability where store_key is null)
       select coalesce(nullif(s.category_path,''),'(uncategorised)') category,
              sum(a.osa_available_obs)::float8/nullif(sum(a.osa_eligible_obs),0)*100 osa,
              count(distinct a.sidnl_id) skus
         from dash.availability a join dash.dim_sidnl s using (sidnl_id), d
        where a.store_key is null and a.obs_date = d.dt
        group by 1 having sum(a.osa_eligible_obs) > 0 order by 3 desc limit 20`),
    q(`with d as (select max(obs_date) dt from dash.availability where store_key is null)
       select s.canonical_name name, a.platform, a.city_slug, a.osa_pct::float8 osa,
              a.out_of_stock_stores oos, a.inventory_fe, a.potential_sales_loss::float8 loss, a.priority
         from dash.availability a join dash.dim_sidnl s using (sidnl_id), d
        where a.store_key is null and a.obs_date = d.dt and a.is_critical
        order by a.potential_sales_loss desc nulls last, a.osa_pct limit 15`),
    q(`select distinct obs_date::text d from dash.availability where store_key is null order by 1 desc limit 4`),
  ]);

  const lbl = (i: number) => dates[i]?.d ?? '—';

  return (
    <div className="space-y-6">
      <Header title="Availability" subtitle="OSA, DS listing, stock-outs, RCA" />

      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        {[0, 1, 2, 3].map(i => {
          const rows = dm.filter((r: any) => r[`d${i}`] != null);
          const avg = rows.length ? rows.reduce((s: number, r: any) => s + r[`d${i}`], 0) / rows.length : null;
          return <KpiCard key={i} title={i === 0 ? 'OSA latest' : `OSA D-${i}`} value={pct(avg)} subtitle={lbl(i)}
                          />;
        })}
      </div>

      <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
        <h2 className="section-title">OSA by platform × city (latest 4 observation days)</h2>
        <div className="overflow-x-auto">
          <table className="data-table">
            <thead><tr><th>Platform</th><th>City</th>{[0,1,2,3].map(i => <th key={i}>{lbl(i)}</th>)}</tr></thead>
            <tbody>
              {dm.map((r: any) => (
                <tr key={`${r.platform}-${r.city_slug}`}>
                  <td className="font-medium capitalize">{r.platform}</td>
                  <td>{r.city_name ?? r.city_slug}</td>
                  {[0,1,2,3].map(i => <td key={i} className={osaColor(r[`d${i}`])}>{pct(r[`d${i}`])}</td>)}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
          <h2 className="section-title">OSA by brand (latest day)</h2>
          {brands.length ? <HBar data={brands} label="brand" value="osa" max={100} /> : <Empty what="No data." />}
        </div>
        <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
          <h2 className="section-title">OSA by category (latest day)</h2>
          <div className="overflow-auto max-h-80">
            <table className="data-table">
              <thead><tr><th>Category</th><th>OSA %</th><th>SKUs</th></tr></thead>
              <tbody>
                {cats.map((r: any) => (
                  <tr key={r.category}><td>{r.category}</td><td className={osaColor(r.osa)}>{pct(r.osa)}</td><td>{r.skus}</td></tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
        <h2 className="section-title">Critical issues (SKU × city, latest day)</h2>
        {critical.length === 0 ? <Empty what="No critical SKU-city issues on the latest day." /> : (
          <div className="overflow-x-auto">
            <table className="data-table">
              <thead><tr><th>SKU</th><th>Platform</th><th>City</th><th>OSA</th><th>OOS stores</th><th>Inventory FE</th><th>Potential loss</th><th>Priority</th></tr></thead>
              <tbody>
                {critical.map((r: any, i: number) => (
                  <tr key={i}>
                    <td>{r.name}</td><td className="capitalize">{r.platform}</td><td>{r.city_slug}</td>
                    <td className={osaColor(r.osa)}>{pct(r.osa)}</td><td>{r.oos ?? '—'}</td>
                    <td>{r.inventory_fe ?? '—'}</td><td>{r.loss != null ? `₹${n(r.loss, 0)}` : '—'}</td><td>{r.priority ?? '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}
