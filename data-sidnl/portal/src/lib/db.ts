import 'server-only';
import { Pool } from 'pg';

// Server-side only. The dash tables have RLS enabled with no policies, so the
// browser (anon key) cannot read them; pages query through this pool instead.
// DATABASE_URL = Supabase pooler connection string (use a read-only role).
const g = globalThis as unknown as { _dashPool?: Pool };
const pool =
  g._dashPool ??
  new Pool({
    connectionString: process.env.DATABASE_URL,
    max: 5,
    ssl: { rejectUnauthorized: false },
    statement_timeout: 15000,
  });
if (process.env.NODE_ENV !== 'production') g._dashPool = pool;

export async function q<T = any>(sql: string, params: any[] = []): Promise<T[]> {
  const r = await pool.query(sql, params);
  return r.rows as T[];
}

export const n = (v: any, d = 1) =>
  v == null || Number.isNaN(Number(v)) ? '—' : Number(v).toFixed(d);
export const pct = (v: any, d = 1) => (v == null ? '—' : `${Number(v).toFixed(d)}%`);
export const osaColor = (v: number | null) =>
  v == null ? 'text-slate-400' : v >= 80 ? 'text-emerald-600' : v >= 60 ? 'text-amber-600' : 'text-red-600';

/** Latest refresh time + error state, shown in every page header. */
export async function freshness() {
  const r = await q<{ refreshed_at: string; err: string | null }>(
    `select (select max(refreshed_at) from dash.availability) refreshed_at,
            (select value from dash.refresh_state where key = 'last_error') err`
  );
  return r[0];
}
