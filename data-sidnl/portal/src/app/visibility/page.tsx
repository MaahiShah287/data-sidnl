import KpiCard from '@/components/KpiCard';
import Header, { Empty } from '@/components/Header';
import { HBar } from '@/components/Charts';
import { q, pct, n } from '@/lib/db';

export const dynamic = 'force-dynamic';

export default async function VisibilityPage() {
  const [[k], brands, kws] = await Promise.all([
    q(`with d as (select max(obs_date) dt from dash.visibility where search_type='category')
       select dt::text, count(distinct (platform, city_slug, search_term)) markets,
              avg(avg_search_rank)::float8 rank,
              sum(stores_listed)::float8/nullif(sum(stores_scanned),0)*100 coverage
         from dash.visibility, d where search_type='category' and obs_date = d.dt group by dt`),
    // brand SOV = sum of its SKUs' SOV inside each market; then averaged across markets
    q(`with d as (select max(obs_date) dt from dash.visibility where search_type='category'),
       m as (select s.brand_key, v.platform, v.city_slug, v.search_term,
                    sum(v.share_of_voice_pct) sov, avg(v.avg_search_rank) rank
               from dash.visibility v join dash.dim_sidnl s using (sidnl_id), d
              where v.search_type='category' and v.obs_date = d.dt
              group by 1,2,3,4)
       select brand_key brand, avg(sov)::float8 sov, avg(rank)::float8 rank, count(*) markets
         from m group by 1 order by 2 desc nulls last limit 15`),
    q(`with d as (select max(obs_date) dt from dash.visibility where search_type='keyword')
       select v.search_term kw, s.canonical_name name, v.platform, v.city_slug,
              v.avg_search_rank::float8 rank, v.best_search_rank, v.impressions
         from dash.visibility v join dash.dim_sidnl s using (sidnl_id), d
        where v.search_type='keyword' and v.obs_date = d.dt
        order by v.avg_search_rank nulls last limit 25`),
  ]);

  return (
    <div className="space-y-6">
      <Header title="Visibility" subtitle="Share of voice, search rank, listing coverage" />
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <KpiCard title="Avg search rank" value={n(k?.rank)} subtitle={`as of ${k?.dt ?? '—'}`} />
        <KpiCard title="Listing coverage" value={pct(k?.coverage)} />
        <KpiCard title="Category markets" value={k?.markets ?? '—'} />
        <KpiCard title="Brands with SOV" value={brands.length} />
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
          <h2 className="section-title">Brand share of voice (avg across category markets)</h2>
          {brands.length ? <HBar data={brands} label="brand" value="sov" /> : <Empty what="No category shelf data on the latest day." />}
        </div>
        <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
          <h2 className="section-title">Brand average search rank</h2>
          <table className="data-table">
            <thead><tr><th>Brand</th><th>Avg rank</th><th>Markets</th></tr></thead>
            <tbody>{brands.map((r: any) => (<tr key={r.brand}><td>{r.brand}</td><td>{n(r.rank)}</td><td>{r.markets}</td></tr>))}</tbody>
          </table>
        </div>
      </div>

      <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
        <h2 className="section-title">Keyword tracking (latest day)</h2>
        {kws.length === 0 ? <Empty what="No keyword observations on the latest day." /> : (
          <div className="overflow-x-auto"><table className="data-table">
            <thead><tr><th>Keyword</th><th>SKU</th><th>Platform</th><th>City</th><th>Avg rank</th><th>Best rank</th></tr></thead>
            <tbody>{kws.map((r: any, i: number) => (
              <tr key={i}><td>{r.kw}</td><td>{r.name}</td><td className="capitalize">{r.platform}</td><td>{r.city_slug}</td>
                <td>{n(r.rank)}</td><td>{r.best_search_rank ?? '—'}</td></tr>))}</tbody>
          </table></div>
        )}
      </div>
    </div>
  );
}
