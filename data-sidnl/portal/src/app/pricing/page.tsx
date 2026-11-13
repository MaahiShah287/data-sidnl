import KpiCard from '@/components/KpiCard';
import Header, { Empty } from '@/components/Header';
import FilterBar from '@/components/FilterBar';
import { Trend } from '@/components/Charts';
import { q, pct, n, SP, pickPlatform, pickBrand, fP, fB, clientBrands } from '@/lib/db';

export const dynamic = 'force-dynamic';

export default async function PricingPage({ searchParams }: { searchParams?: SP }) {
  const pf = pickPlatform(searchParams);
  const bk = pickBrand(searchParams);
  const args = [pf, bk];
  const F = `${fP('p.')} and ${fB('p.')}`;

  const [[k], trend, cities, up, down, brands] = await Promise.all([
    q(`with d as (select max(obs_date) dt from dash.pricing p where ${F})
       select dt::text, avg(selling_price)::float8 asp, avg(mrp)::float8 mrp, avg(weighted_discount_pct)::float8 disc,
              avg(price_per_100g)::float8 p100, count(*) filter (where is_parity_break) breaks, count(*) n
         from dash.pricing p, d where p.obs_date = d.dt and ${F} group by dt`, args),
    q(`select obs_date::text d, avg(selling_price)::float8 sp, avg(mrp)::float8 mrp, avg(weighted_discount_pct)::float8 disc
         from dash.pricing p where ${F} group by 1 order by 1`, args),
    q(`with d as (select max(obs_date) dt from dash.pricing p where ${F})
       select p.platform, p.city_slug, c.city_name, avg(p.selling_price)::float8 sp,
              min(p.min_selling_price)::float8 lo, max(p.max_selling_price)::float8 hi,
              avg(p.weighted_discount_pct)::float8 disc, avg(p.price_vs_national_pct)::float8 vs_nat
         from dash.pricing p left join dash.dim_city c using (city_slug), d
        where p.obs_date = d.dt and ${F} group by 1,2,3 order by 1,2`, args),
    q(`select s.canonical_name name, p.platform, p.city_slug, p.selling_price::float8 sp, p.sp_change_pct::float8 chg
         from dash.pricing p join dash.dim_sidnl s using (sidnl_id)
        where p.sp_change_pct > 0 and ${F}
          and p.obs_date = (select max(obs_date) from dash.pricing p where sp_change_pct is not null and ${F})
        order by chg desc limit 10`, args),
    q(`select s.canonical_name name, p.platform, p.city_slug, p.selling_price::float8 sp, p.sp_change_pct::float8 chg
         from dash.pricing p join dash.dim_sidnl s using (sidnl_id)
        where p.sp_change_pct < 0 and ${F}
          and p.obs_date = (select max(obs_date) from dash.pricing p where sp_change_pct is not null and ${F})
        order by chg limit 10`, args),
    clientBrands(),
  ]);

  const Movers = ({ title, rows }: { title: string; rows: any[] }) => (
    <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
      <h2 className="section-title">{title}</h2>
      {rows.length === 0 ? <Empty what="No price changes recorded." /> : (
        <table className="data-table">
          <thead><tr><th>SKU</th><th>Platform</th><th>City</th><th>SP</th><th>Δ%</th></tr></thead>
          <tbody>{rows.map((r, i) => (
            <tr key={i}><td>{r.name}</td><td className="capitalize">{r.platform}</td><td>{r.city_slug}</td>
              <td>₹{n(r.sp)}</td><td className={r.chg > 0 ? 'text-red-600' : 'text-emerald-600'}>{pct(r.chg)}</td></tr>
          ))}</tbody>
        </table>
      )}
    </div>
  );

  return (
    <div className="space-y-6">
      <Header title="Pricing" subtitle="MRP, selling price, discount, parity (client brands; competitors are on the Competitors page)" />
      <FilterBar base="/pricing" platform={pf} brand={bk} brands={brands} />
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <KpiCard title="Avg selling price" value={k?.asp != null ? `₹${n(k.asp)}` : '—'} subtitle={`as of ${k?.dt ?? '—'}`} />
        <KpiCard title="Avg MRP" value={k?.mrp != null ? `₹${n(k.mrp)}` : '—'} />
        <KpiCard title="Avg discount" value={pct(k?.disc)} />
        <KpiCard title="Parity breaks" value={k?.breaks ?? '—'} subtitle={`of ${k?.n ?? 0} SKU-cities`} />
      </div>

      <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
        <h2 className="section-title">Average discount % by day</h2>
        {trend.length ? <Trend data={trend} x="d" series={['disc']} /> : <Empty what="No pricing rows for this filter." />}
      </div>

      <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
        <h2 className="section-title">City price comparison (latest day)</h2>
        <div className="overflow-x-auto">
          <table className="data-table">
            <thead><tr><th>Platform</th><th>City</th><th>Avg SP</th><th>Lowest</th><th>Highest</th><th>Discount</th><th>Vs national</th></tr></thead>
            <tbody>{cities.map((r: any) => (
              <tr key={`${r.platform}-${r.city_slug}`}>
                <td className="capitalize font-medium">{r.platform}</td><td>{r.city_name ?? r.city_slug}</td>
                <td>₹{n(r.sp)}</td><td>₹{n(r.lo)}</td><td>₹{n(r.hi)}</td><td>{pct(r.disc)}</td><td>{pct(r.vs_nat)}</td>
              </tr>))}</tbody>
          </table>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <Movers title="Biggest price increases" rows={up} />
        <Movers title="Biggest price decreases" rows={down} />
      </div>
    </div>
  );
}
