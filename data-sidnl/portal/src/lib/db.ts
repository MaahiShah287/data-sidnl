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

/** Latest gold refresh state, shown in every page header.
 *
 *  Reads dash.v_refresh_status (one row per dash table) and returns the
 *  worst-case summary: the most recent successful refresh, whether any table
 *  is stale, and whether any refresh is currently failing. NULL is returned as
 *  "not measured" (never displayed as 0 or false). */
export async function freshness() {
  const rows = await q<{
    last_refreshed_at: string | null;
    is_stale: boolean | null;
    refresh_failing: boolean | null;
    last_error: string | null;
  }>(
    `select
       max(last_refreshed_at)                              as last_refreshed_at,
       bool_or(is_stale)                                   as is_stale,
       bool_or(refresh_failing)                            as refresh_failing,
       (array_agg(last_error order by last_attempt_at desc) filter (where last_error is not null))[1]
                                                           as last_error
     from dash.v_refresh_status`
  );
  return rows[0] ?? null;
}

/** Per-platform data freshness banner (from bronze).
 *
 *  Returns rows from dash.v_platform_freshness where status = 'stale'.
 *  Empty array = all platforms fresh (no banner shown). */
export async function stalePlatforms() {
  return q<{ platform: string; hours_since_last_data: number; stale_sources: string[] }>(
    `select platform, hours_since_last_data::float8, stale_sources
       from dash.v_platform_freshness
      where status = 'stale'
      order by hours_since_last_data desc`
  );
}
