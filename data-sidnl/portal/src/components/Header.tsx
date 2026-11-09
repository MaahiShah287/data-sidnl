import { freshness } from '@/lib/db';

export default async function Header({ title, subtitle }: { title: string; subtitle: string }) {
  const f = await freshness();
  return (
    <div className="space-y-2">
      <div>
        <h1 className="text-2xl font-bold text-slate-900">{title}</h1>
        <p className="text-sm text-slate-500 mt-0.5">
          {subtitle} · refreshed {f?.refreshed_at ? new Date(f.refreshed_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' }) : '—'} IST
        </p>
      </div>
      {f?.err && (
        <div className="bg-amber-50 border border-amber-200 rounded-lg p-3 text-xs text-amber-800">
          Last dash refresh reported an error; data may be stale: {f.err}
        </div>
      )}
    </div>
  );
}

export function Empty({ what }: { what: string }) {
  return (
    <div className="bg-white rounded-xl border border-dashed border-slate-300 p-5 text-sm text-slate-500">
      {what}
    </div>
  );
}
