import { freshness, stalePlatforms } from '@/lib/db';

export default async function Header({ title, subtitle }: { title: string; subtitle: string }) {
  const [f, stale] = await Promise.all([freshness(), stalePlatforms()]);
  return (
    <div className="space-y-2">
      <div>
        <h1 className="text-2xl font-bold text-slate-900">{title}</h1>
        <p className="text-sm text-slate-500 mt-0.5">
          {subtitle} · refreshed{' '}
          {f?.last_refreshed_at
            ? new Date(f.last_refreshed_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' })
            : '—'}{' '}
          IST
          {f?.is_stale && ' · ⚠ dash data stale'}
        </p>
      </div>

      {/* Gold refresh failing banner */}
      {f?.refresh_failing && (
        <div className="bg-amber-50 border border-amber-200 rounded-lg p-3 text-xs text-amber-800">
          Last dash refresh failed; data may be stale.
          {f.last_error ? ` Error: ${f.last_error}` : ''}
        </div>
      )}

      {/* Per-platform stale data banners (from bronze freshness) */}
      {stale.map((p) => (
        <div
          key={p.platform}
          className="bg-slate-50 border border-slate-200 rounded-lg p-3 text-xs text-slate-700"
        >
          {p.platform} data stale — no new data for{' '}
          {p.hours_since_last_data != null ? `${p.hours_since_last_data.toFixed(1)} h` : 'an unknown time'}.
          {p.stale_sources?.length ? ` Stale sources: ${p.stale_sources.join(', ')}.` : ''}
        </div>
      ))}
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
