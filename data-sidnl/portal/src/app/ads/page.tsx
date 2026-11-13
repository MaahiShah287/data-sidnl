import KpiCard from '@/components/KpiCard';
import Header, { Empty } from '@/components/Header';
import FilterBar from '@/components/FilterBar';
import { Trend } from '@/components/Charts';
import { qSafe, pct, n, inr, num, SP, pickPlatform } from '@/lib/db';

export const dynamic = 'force-dynamic';

// First-party ads (retail-media console exports). Queries follow docs/FRONTEND_QUERIES.md: ONE report_level per
// query ('campaign' for totals and trends, 'keyword' / 'placement' for the detail) - levels are never added together.
// Zepto first-party ads: ad-console export by page (no dates, campaigns or keywords) + the ad-wallet ledger.
// Ratios are recomputed from additive columns (sum / sum); the export's own cpc / roas columns are not used.
async function ZeptoAds() {
  const [tot, pages, wallet, days] = await Promise.all([
    qSafe(`select sum(spend)::float8 spend, sum(revenue)::float8 revenue, sum(impressions)::float8 imps, sum(clicks)::float8 clicks,
                  sum(atc)::float8 atc, sum(orders)::float8 orders,
                  (sum(revenue) / nullif(sum(spend), 0))::float8 roas, (100.0 * sum(spend) / nullif(sum(revenue), 0))::float8 acos,
                  (100.0 * sum(clicks) / nullif(sum(impressions), 0))::float8 ctr, (sum(spend) / nullif(sum(clicks), 0))::float8 cpc,
                  (1000.0 * sum(spend) / nullif(sum(impressions), 0))::float8 cpm, (100.0 * sum(orders) / nullif(sum(clicks), 0))::float8 cvr,
                  max(snapshot_label) snapshot
             from dash.v_fp_ad_page`),
    qSafe(`select page_name, impressions::float8 imps, clicks::float8 clicks, atc::float8 atc, orders::float8 orders, revenue::float8 revenue, spend::float8 spend,
                  ctr_pct::float8 ctr, cpc::float8 cpc, cvr_pct::float8 cvr, roas::float8 roas, acos_pct::float8 acos
             from dash.v_fp_ad_page order by spend desc, impressions desc`),
    qSafe(`select sum(ad_spend)::float8 ad_spend, sum(topup)::float8 topup, sum(incentive)::float8 incentive, sum(refunds)::float8 refunds,
                  min(day)::text d0, max(day)::text d1, count(*)::int days from dash.v_fp_ad_wallet_day`),
    qSafe(`select day::text d, ad_spend::float8 spend from dash.v_fp_ad_wallet_day
            where day > (select max(day) from dash.v_fp_ad_wallet_day) - 90 order by day`),
  ]);
  const t = tot.rows[0];
  const w = wallet.rows[0];
  const err = tot.error ?? pages.error;
  return (
    <div className="space-y-6">
      <Header title="Ads" subtitle="Spend, attributed sales, ROAS, CTR, CPC, conversion (first-party Zepto ad console)" />
      <FilterBar base="/ads" platform="zepto" allPlatforms={false} />
      {err && <Empty what={`Zepto ad views could not be read: ${err.slice(0, 160)}. Apply sql/migrations/dash_016_fp_metric_views.sql.`} />}
      {!err && (!t || t.spend == null) && <Empty what="No Zepto ad-console export loaded yet." />}
      {!err && t && t.spend != null && (
        <>
          <p className="text-xs text-slate-500">
            Zepto ad console export ({t.snapshot}). It is one snapshot by ad page: it has no dates, campaigns or keywords, so ROAS / impression
            trends, campaign performance and keyword metrics are not available for Zepto. The daily ad-spend chart comes from the ad-wallet ledger, which is
            a different source and will not equal the page spend total.
          </p>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            <KpiCard title="Ad spend" value={inr(t.spend)} subtitle="all pages in the export" />
            <KpiCard title="Attributed sales" value={inr(t.revenue)} />
            <KpiCard title="ROAS" value={t.roas != null ? `${n(t.roas, 2)}x` : null} subtitle={t.acos != null ? `ACOS ${n(t.acos, 1)}%` : undefined} />
            <KpiCard title="Impressions" value={num(t.imps)} subtitle={`CPM ${inr(t.cpm, 2)}`} />
            <KpiCard title="Clicks" value={num(t.clicks)} subtitle={`CTR ${pct(t.ctr, 2)}`} />
            <KpiCard title="CPC" value={inr(t.cpc, 2)} subtitle="spend ÷ clicks" />
            <KpiCard title="Orders" value={num(t.orders)} subtitle={`conversion ${pct(t.cvr, 2)} of clicks`} />
            <KpiCard title="Add-to-carts" value={num(t.atc)} />
          </div>

          <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
            <h2 className="section-title">Performance by ad page (CTR vs conversion at the same grain)</h2>
            <div className="overflow-auto"><table className="data-table">
              <thead><tr><th>Page</th><th>Spend</th><th>Sales</th><th>ROAS</th><th>Impr.</th><th>Clicks</th><th>CTR</th><th>CPC</th><th>Orders</th><th>CVR</th><th>ATC</th></tr></thead>
              <tbody>{pages.rows.map((r: any) => (
                <tr key={r.page_name}><td className="max-w-xs truncate" title={r.page_name}>{r.page_name}</td><td>{inr(r.spend)}</td><td>{inr(r.revenue)}</td>
                  <td>{r.roas != null ? `${n(r.roas, 2)}x` : '—'}</td><td>{num(r.imps)}</td><td>{num(r.clicks)}</td><td>{r.ctr != null ? pct(r.ctr, 2) : '—'}</td>
                  <td>{r.cpc != null ? inr(r.cpc, 2) : '—'}</td><td>{num(r.orders)}</td><td>{r.cvr != null ? pct(r.cvr, 2) : '—'}</td><td>{num(r.atc)}</td></tr>))}</tbody>
            </table></div>
            <p className="text-xs text-slate-400 mt-2">— means the denominator was zero (no clicks / spend / impressions), never a zero ratio.</p>
          </div>

          {w && (
            <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
              <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
                <h2 className="section-title">Ad-wallet spend by day, last 90 days (₹)</h2>
                <Trend data={days.rows} x="d" series={['spend']} suffix="" />
              </div>
              <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
                <h2 className="section-title">Ad-wallet ledger ({w.d0} → {w.d1})</h2>
                <table className="data-table"><tbody>
                  <tr><td>Ad spend debited</td><td>{inr(w.ad_spend)}</td></tr>
                  <tr><td>Postpaid top-ups credited</td><td>{inr(w.topup)}</td></tr>
                  <tr><td>Incentive credits</td><td>{inr(w.incentive)}</td></tr>
                  <tr><td>Refund debits</td><td>{inr(w.refunds)}</td></tr>
                  <tr><td>Days with activity</td><td>{w.days}</td></tr>
                </tbody></table>
              </div>
            </div>
          )}
        </>
      )}
    </div>
  );
}

export default async function AdsPage({ searchParams }: { searchParams?: SP }) {
  const platform = pickPlatform(searchParams) ?? 'zepto';
  if (platform === 'zepto') return <ZeptoAds />;
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
