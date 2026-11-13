import KpiCard from '@/components/KpiCard';
import Header, { Empty } from '@/components/Header';
import FilterBar from '@/components/FilterBar';
import { Trend } from '@/components/Charts';
import { qSafe, pct, n, SP, pickPlatform } from '@/lib/db';

export const dynamic = 'force-dynamic';

// First-party ads (retail-media console exports). Queries follow docs/FRONTEND_QUERIES.md: ONE report_level per
// query ('campaign' for totals and trends, 'keyword' / 'placement' for the detail) - levels are never added together.
export default async function AdsPage({ searchParams }: { searchParams?: SP }) {
  const platform = pickPlatform(searchParams) ?? 'blinkit';
  const W = `platform = $1`;

  const [kpi, trend, kw, plc, period, sov] = await Promise.all([
    qSafe(`select sum(ad_spend)::float8 spend, sum(attributed_sales)::float8 sales,
                  (sum(attributed_sales) / nullif(sum(ad_spend), 0))::float8 roas,
                  (sum(direct_sales) / nullif(sum(ad_spend), 0))::float8 droas,
                  sum(impressions)::float8 imps, (sum(ad_spend) * 1000 / nullif(sum(impressions), 0))::float8 cpm,
                  sum(atc)::float8 atc, sum(total_qty_sold)::float8 units, sum(new_users_acquired)::float8 users,
                  min(obs_date)::text d0, max(obs_date)::text d1
             from dash.ads where ${W} and report_level = 'campaign'`, [platform]),
    qSafe(`select obs_date::text d, sum(ad_spend)::float8 spend, sum(attributed_sales)::float8 sales,
                  (sum(attributed_sales) / nullif(sum(ad_spend), 0))::float8 roas
             from dash.ads where ${W} and report_level = 'campaign' group by 1 order by 1`, [platform]),
    qSafe(`select keyword, sum(ad_spend)::float8 spend, sum(attributed_sales)::float8 sales, sum(impressions)::float8 imps,
                  (sum(attributed_sales) / nullif(sum(ad_spend), 0))::float8 roas,
                  min(most_viewed_position) best_pos, max(kw_volume_monthly) searches, count(distinct obs_date)::int days
             from dash.ads where ${W} and report_level = 'keyword'
            group by keyword order by spend desc limit 20`, [platform]),
    qSafe(`select placement, sum(ad_spend)::float8 spend, sum(impressions)::float8 imps, sum(attributed_sales)::float8 sales,
                  (sum(attributed_sales) / nullif(sum(ad_spend), 0))::float8 roas, sum(new_users_acquired)::float8 users
             from dash.ads where ${W} and report_level = 'placement' group by placement order by spend desc`, [platform]),
    qSafe(`select campaign_id, campaign_name, campaign_type, period_start::text ps, period_end::text pe, total_budget::float8 budget,
                  claimables::float8, budget_utilisation_pct::float8 util, impressions::float8 imps, spend_reconciled
             from dash.ads_campaign_period where ${W} order by period_end desc, campaign_id`, [platform]),
    qSafe(`select keyword, period_start::text ps, period_end::text pe, searches::float8, sponsored_sov_pct::float8 sov,
                  ad_impressions::float8 imps, ad_spend::float8 spend, total_roas::float8 roas
             from dash.ads_keyword_sov where ${W} order by period_end desc, sponsored_sov_pct desc nulls last`, [platform]),
  ]);

  const k = kpi.rows[0];
  const none = !k || k.spend == null;
  const err = kpi.error;

  return (
    <div className="space-y-6">
      <Header title="Ads" subtitle="Spend, attributed sales, ROAS, keywords, placements, share of voice (first-party ad-console exports)" />
      <FilterBar base="/ads" platform={platform} allPlatforms={false} />

      {err && <Empty what={`Ads tables could not be read: ${err.slice(0, 160)}`} />}
      {!err && none && (
        <Empty what={platform === 'zepto'
          ? 'Zepto first-party ads: no export loaded yet. Send the Zepto ads-console export and it is loaded the same way as Blinkit (bronze table, silver loader, dash.ads).'
          : 'No ads rows for this platform.'} />
      )}

      {!err && !none && (
        <>
          <p className="text-xs text-slate-500">{platform} · {k.d0} → {k.d1}. Not in the export, so shown as unavailable (never 0): clicks, CTR, CPC, conversion rate, AOV.</p>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            <KpiCard title="Ad spend" value={`₹${n(k.spend, 0)}`} />
            <KpiCard title="Attributed sales" value={`₹${n(k.sales, 0)}`} />
            <KpiCard title="Total ROAS" value={k.roas != null ? `${n(k.roas, 2)}x` : '—'} subtitle={`direct ${k.droas != null ? n(k.droas, 2) : '—'}x`} />
            <KpiCard title="Impressions" value={n(k.imps, 0)} subtitle={`eff. CPM ₹${n(k.cpm, 2)}`} />
            <KpiCard title="Add-to-carts" value={n(k.atc, 0)} />
            <KpiCard title="Units sold (ads)" value={n(k.units, 0)} />
            <KpiCard title="New users" value={n(k.users, 0)} />
            <KpiCard title="Clicks / CTR / CPC" value={null} unavailable subtitle="not in the export" />
          </div>

          <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
            <h2 className="section-title">Spend vs attributed sales by day (₹) and ROAS</h2>
            <Trend data={trend.rows} x="d" series={['spend', 'sales']} suffix="" />
            <Trend data={trend.rows} x="d" series={['roas']} suffix="x" />
          </div>

          <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
              <h2 className="section-title">Keyword leaderboard (by spend; ROAS shown)</h2>
              <div className="overflow-auto max-h-96"><table className="data-table">
                <thead><tr><th>Keyword</th><th>Spend</th><th>Sales</th><th>ROAS</th><th>Impr.</th><th>Best pos</th><th>Days</th></tr></thead>
                <tbody>{kw.rows.map((r: any) => (
                  <tr key={r.keyword}><td>{r.keyword}</td><td>₹{n(r.spend, 0)}</td><td>₹{n(r.sales, 0)}</td>
                    <td>{r.roas != null ? `${n(r.roas, 2)}x` : '—'}</td><td>{n(r.imps, 0)}</td><td>{r.best_pos ?? '—'}</td><td>{r.days}</td></tr>))}</tbody>
              </table></div>
            </div>
            <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
              <h2 className="section-title">Recommendation placements</h2>
              {plc.rows.length === 0 ? <Empty what="No placement rows." /> : (
                <table className="data-table">
                  <thead><tr><th>Placement</th><th>Spend</th><th>Impr.</th><th>Sales</th><th>ROAS</th><th>New users</th></tr></thead>
                  <tbody>{plc.rows.map((r: any) => (
                    <tr key={r.placement}><td>{r.placement}</td><td>₹{n(r.spend, 0)}</td><td>{n(r.imps, 0)}</td><td>₹{n(r.sales, 0)}</td>
                      <td>{r.roas != null ? `${n(r.roas, 2)}x` : '—'}</td><td>{n(r.users, 0)}</td></tr>))}</tbody>
                </table>
              )}
            </div>
          </div>

          <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
              <h2 className="section-title">Campaign budget and claimables (month to date)</h2>
              <table className="data-table">
                <thead><tr><th>Campaign</th><th>Period</th><th>Budget</th><th>Claimables</th><th>Used</th><th>Reconciled</th></tr></thead>
                <tbody>{period.rows.map((r: any) => (
                  <tr key={`${r.campaign_id}-${r.ps}`}><td>{r.campaign_name}</td><td>{r.ps} → {r.pe}</td><td>₹{n(r.budget, 0)}</td>
                    <td>₹{n(r.claimables, 2)}</td><td>{pct(r.util, 2)}</td><td>{r.spend_reconciled ? 'yes' : 'no'}</td></tr>))}</tbody>
              </table>
            </div>
            <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
              <h2 className="section-title">Sponsored share of voice (keyword)</h2>
              <table className="data-table">
                <thead><tr><th>Keyword</th><th>Period</th><th>Searches</th><th>Sponsored SoV</th><th>ROAS</th></tr></thead>
                <tbody>{sov.rows.map((r: any, i: number) => (
                  <tr key={i}><td>{r.keyword}</td><td>{r.ps} → {r.pe}</td><td>{n(r.searches, 0)}</td><td>{pct(r.sov, 2)}</td>
                    <td>{r.roas != null ? `${n(r.roas, 2)}x` : '—'}</td></tr>))}</tbody>
              </table>
            </div>
          </div>
        </>
      )}
    </div>
  );
}
