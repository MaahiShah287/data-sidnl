import Header from '@/components/Header';
import KpiCard from '@/components/KpiCard';
import { Pills } from '@/components/FilterBar';
import { SP, pickParam } from '@/lib/db';
import data from '@/lib/metricCoverage.json';

export const dynamic = 'force-dynamic';

type M = { n: number; sec: number; name: string; status: 'live' | 'proxy' | 'partial' | 'feed';
           page: string; plat: string; dep: string; needs: string; note: string };

const LABEL: Record<string, string> = { live: 'Visible', proxy: 'Visible (proxy)', partial: 'Partly visible', feed: 'Not visible' };
const BADGE: Record<string, string> = {
  live: 'bg-emerald-50 text-emerald-700 border-emerald-200',
  proxy: 'bg-sky-50 text-sky-700 border-sky-200',
  partial: 'bg-amber-50 text-amber-700 border-amber-200',
  feed: 'bg-slate-100 text-slate-600 border-slate-200',
};

export default async function MetricsPage({ searchParams }: { searchParams?: SP }) {
  const metrics = data.metrics as M[];
  const sections = data.meta.sections as Record<string, string>;
  const status = pickParam(searchParams, 'status');
  const sec = pickParam(searchParams, 'section');
  const count = (s: string) => metrics.filter(m => m.status === s).length;
  const shown = metrics.filter(m => (!status || m.status === status) && (!sec || String(m.sec) === sec));
  const base = '/metrics';

  return (
    <div className="space-y-6">
      <Header title="Metric coverage" subtitle={`${metrics.length} handbook metrics - what is visible, what is not, and why (generated ${data.meta.generated})`} />

      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <KpiCard title="Visible" value={count('live')} subtitle="from a feed we have" />
        <KpiCard title="Visible (proxy)" value={count('proxy')} subtitle="labelled as a proxy" />
        <KpiCard title="Partly visible" value={count('partial')} subtitle="rest needs something missing" />
        <KpiCard title="Not visible" value={count('feed')} subtitle="needs a feed that does not exist yet" />
      </div>

      <div className="bg-amber-50 border border-amber-200 rounded-lg p-3 text-xs text-amber-800 space-y-1">
        <p>Applied 2026-11-13: pipeline fix (silver_075, silver_076), competitor tables (dash_013) and their cron job (dash_014). Scraped figures are current for Blinkit and Zepto.
           Zepto first-party exports (sales, stock, PO, GRN, invoices, payments, ledger, ad console) are loaded (dash.fp_*, views in dash_016) and shown on the Sales, Supply,
           Finance and Ads pages. The Blinkit ad exports were removed from the database, so keyword- and campaign-level ad metrics are not available.</p>
        <p>No sales, GMV, inventory, ads or finance number is ever estimated from scraped prices; those rows are shown as not available.</p>
      </div>

      <div className="flex flex-wrap items-center gap-x-6 gap-y-2 text-xs text-slate-500">
        <div className="flex items-center gap-2"><span>Status</span>
          <Pills base={base} param="status" current={status}
            options={[{ value: null, label: 'All' }, ...Object.entries(LABEL).map(([v, l]) => ({ value: v, label: l }))]}
            keep={{ section: sec }} /></div>
        <div className="flex items-center gap-2"><span>Section</span>
          <Pills base={base} param="section" current={sec}
            options={[{ value: null, label: 'All' }, ...Object.keys(sections).map(k => ({ value: k, label: k }))]}
            keep={{ status }} /></div>
      </div>

      <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm overflow-x-auto">
        <table className="data-table">
          <thead><tr><th>#</th><th>Metric</th><th>Section</th><th>Status</th><th>Where</th><th>Platforms</th><th>Needs / note</th></tr></thead>
          <tbody>
            {shown.map(m => (
              <tr key={m.n}>
                <td>{m.n}</td>
                <td className="font-medium">{m.name}</td>
                <td className="text-slate-500">{m.sec}. {sections[String(m.sec)]}</td>
                <td><span className={`inline-block px-2 py-0.5 rounded-full border text-xs ${BADGE[m.status]}`}>{LABEL[m.status]}</span></td>
                <td>{m.page || '-'}</td>
                <td>{m.plat || '-'}</td>
                <td className="text-xs text-slate-600">
                  {m.dep && <span className="mr-1 px-1.5 py-0.5 rounded bg-slate-100 border border-slate-200">apply {m.dep}</span>}
                  {m.needs && <span><b>Needs:</b> {m.needs}. </span>}
                  {m.note}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {shown.length === 0 && <p className="text-sm text-slate-500">No metrics match this filter.</p>}
      </div>
    </div>
  );
}
