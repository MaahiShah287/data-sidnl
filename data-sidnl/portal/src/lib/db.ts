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

/** Like q(), but never throws: returns the error text instead, so a page can say
 *  "this table is not created yet" (migration pending) instead of crashing. */
export async function qSafe<T = any>(sql: string, params: any[] = []): Promise<{ rows: T[]; error: string | null }> {
  try {
    return { rows: await q<T>(sql, params), error: null };
  } catch (e: any) {
    return { rows: [], error: String(e?.message ?? e) };
  }
}

// ---- page filters (?platform=zepto&brand=mr munchies) -----------------------------------------------------------
export const KNOWN_PLATFORMS = ['blinkit', 'zepto', 'instamart', 'jiomart'];
export type SP = { [k: string]: string | string[] | undefined };
const one = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v);

/** platform filter from the URL; null = all platforms */
export function pickPlatform(sp?: SP): string | null {
  const p = one(sp?.platform)?.toLowerCase();
  return p && KNOWN_PLATFORMS.includes(p) ? p : null;
}
/** brand filter from the URL (silver brand_key, lower-case); null = all brands */
export function pickBrand(sp?: SP): string | null {
  const b = one(sp?.brand)?.toLowerCase().trim();
  return b ? b.slice(0, 80) : null;
}
export const pickParam = (sp: SP | undefined, k: string): string | null => one(sp?.[k])?.trim() || null;

/** SQL fragments for the two filters. Convention: $1 = platform (text|null), $2 = brand_key (text|null). */
export const fP = (a = '') => `($1::text is null or ${a}platform = $1)`;
export const fB = (a = '') =>
  `($2::text is null or ${a}sidnl_id in (select sidnl_id from dash.dim_sidnl where brand_key = $2))`;

/** the client brands (the focal brands of the competitor pages) */
export async function clientBrands() {
  const r = await qSafe<{ brand_key: string; brand_name: string }>(
    `select brand_key, brand_name from dash.dim_brand where is_client order by brand_name`);
  return r.rows;
}

export const n = (v: any, d = 1) =>
  v == null || Number.isNaN(Number(v)) ? '—' : Number(v).toFixed(d);
export const pct = (v: any, d = 1) => (v == null ? '—' : `${Number(v).toFixed(d)}%`);
/** Indian-grouped rupee amount, e.g. ₹12,95,934. null/NaN -> '—' (never shown as 0). */
export const inr = (v: any, d = 0) =>
  v == null || Number.isNaN(Number(v))
    ? '—'
    : `${Number(v) < 0 ? '-' : ''}₹${Math.abs(Number(v)).toLocaleString('en-IN', { minimumFractionDigits: d, maximumFractionDigits: d })}`;
/** Indian-grouped plain number. */
export const num = (v: any, d = 0) =>
  v == null || Number.isNaN(Number(v))
    ? '—'
    : Number(v).toLocaleString('en-IN', { minimumFractionDigits: d, maximumFractionDigits: d });
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
