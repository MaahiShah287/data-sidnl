'use client';
import { useState, useEffect, useCallback } from 'react';
import { createClient } from '@/lib/supabase';
import KpiCard from '@/components/KpiCard';
import {
  BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, Legend,
  LineChart, Line, ResponsiveContainer, PieChart, Pie, Cell
} from 'recharts';
import { RefreshCw, Database, Calendar } from 'lucide-react';
import { format } from 'date-fns';

const COLORS = ['#3b82f6', '#10b981', '#f59e0b', '#ef4444', '#8b5cf6', '#06b6d4'];

export default function OverviewPage() {
  const supabase = createClient();
  const [kpi, setKpi] = useState<any>(null);
  const [platforms, setPlatforms] = useState<any[]>([]);
  const [trend, setTrend] = useState<any[]>([]);
  const [topBrands, setTopBrands] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const [kpiRes, platformRes, trendRes, brandsRes] = await Promise.all([
        supabase.from('v_global_kpi').select('*').schema('gold').single(),
        supabase.from('mv_platform_overview').select('*').schema('gold').order('total_obs', { ascending: false }),
        supabase.from('mv_daily_trend').select('*').schema('gold').order('obs_date'),
        supabase.from('v_top_brands_by_osa').select('*').schema('gold')
          .order('osa_pct', { ascending: false }).limit(10),
      ]);

      if (kpiRes.error) throw kpiRes.error;
      setKpi(kpiRes.data);
      setPlatforms(platformRes.data ?? []);
      setTrend(trendRes.data ?? []);
      setTopBrands(brandsRes.data ?? []);
    } catch (e: any) {
      setError(e.message ?? 'Failed to load data');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  const fmt = (v: any, d = 1) =>
    v == null ? '—' : typeof v === 'number' ? v.toFixed(d) : v;

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-slate-900">Overview</h1>
          <p className="text-sm text-slate-500 mt-0.5">
            Aggregated KPIs from Blinkit + Zepto Silver data · Gold Layer
          </p>
        </div>
        <button
          onClick={load}
          className="flex items-center gap-2 px-4 py-2 text-sm font-medium bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
        >
          <RefreshCw className="w-4 h-4" />
          Refresh
        </button>
      </div>

      {/* Error */}
      {error && (
        <div className="bg-red-50 border border-red-200 rounded-lg p-4">
          <p className="text-sm text-red-700">
            <strong>Error:</strong> {error}
            {error.includes('does not exist') && (
              <span className="block mt-1 text-xs">
                Run <code>000_APPLY_ALL_GOLD.sql</code> in Supabase SQL Editor first, then refresh materialized views.
              </span>
            )}
          </p>
        </div>
      )}

      {/* Data freshness banner */}
      {kpi?.data_as_of && (
        <div className="flex items-center gap-2 text-xs text-slate-500 bg-blue-50 border border-blue-100 rounded-lg px-4 py-2">
          <Calendar className="w-3.5 h-3.5" />
          <span>Data as of: <strong>{format(new Date(kpi.data_as_of), 'dd MMM yyyy, HH:mm')}</strong></span>
          <Database className="w-3.5 h-3.5 ml-2" />
          <span>Total active days: <strong>{kpi.total_active_days}</strong></span>
        </div>
      )}

      {/* KPI Cards */}
      <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 gap-4">
        <KpiCard title="Total SKUs"       value={kpi?.total_skus?.toLocaleString()}          loading={loading} />
        <KpiCard title="Total Brands"     value={kpi?.total_brands?.toLocaleString()}         loading={loading} />
        <KpiCard title="Platforms"        value={kpi?.total_platforms}                        loading={loading} />
        <KpiCard title="Cities"           value={kpi?.total_cities}                           loading={loading} />
        <KpiCard title="Stores"           value={kpi?.total_stores?.toLocaleString()}         loading={loading} />
        <KpiCard title="Overall OSA"      value={fmt(kpi?.global_osa_pct)} unit="%" badge="Availability" badgeColor="green" loading={loading} />
        <KpiCard title="Avg Selling Price" value={kpi?.global_avg_sp ? `₹${fmt(kpi.global_avg_sp)}` : null} loading={loading} />
        <KpiCard title="Avg Discount"     value={fmt(kpi?.global_avg_discount_pct)} unit="%" loading={loading} />
        <KpiCard title="Total Observations" value={kpi?.total_obs?.toLocaleString()}          loading={loading} />
        <KpiCard title="Shelf Positions"  value={kpi?.total_shelf_obs?.toLocaleString()}      loading={loading} />
        <KpiCard title="Sales Value (MRP)"    value={null} unavailable loading={false} subtitle="No transaction data" />
        <KpiCard title="Market Share %"       value={null} unavailable loading={false} subtitle="No sales data" />
        <KpiCard title="PO Count"             value={null} unavailable loading={false} subtitle="No PO tables" />
        <KpiCard title="Critical SKUs"        value={null} unavailable loading={false} subtitle="Pending thresholds" />
      </div>

      {/* OSA Trend chart */}
      {trend.length > 0 && (
        <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
          <h2 className="section-title">Daily OSA % Trend by Platform</h2>
          <ResponsiveContainer width="100%" height={260}>
            <LineChart data={trend} margin={{ top: 5, right: 20, left: 0, bottom: 5 }}>
              <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
              <XAxis dataKey="obs_date" tick={{ fontSize: 11 }} tickFormatter={v => v?.slice(5)} />
              <YAxis domain={[0, 100]} tickFormatter={v => `${v}%`} tick={{ fontSize: 11 }} />
              <Tooltip formatter={(v: any) => [`${v}%`, 'OSA']} />
              <Legend />
              {[...new Set(trend.map(r => r.platform))].map((p, i) => (
                <Line
                  key={p as string}
                  type="monotone"
                  dataKey="osa_pct"
                  data={trend.filter(r => r.platform === p)}
                  name={p as string}
                  stroke={COLORS[i % COLORS.length]}
                  dot={false}
                  strokeWidth={2}
                />
              ))}
            </LineChart>
          </ResponsiveContainer>
        </div>
      )}

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Platform comparison */}
        {platforms.length > 0 && (
          <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
            <h2 className="section-title">Platform Comparison</h2>
            <ResponsiveContainer width="100%" height={220}>
              <BarChart data={platforms} margin={{ top: 5, right: 10, left: 0, bottom: 5 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
                <XAxis dataKey="platform" tick={{ fontSize: 12 }} />
                <YAxis yAxisId="pct" domain={[0, 100]} tickFormatter={v => `${v}%`} tick={{ fontSize: 11 }} />
                <YAxis yAxisId="price" orientation="right" tickFormatter={v => `₹${v}`} tick={{ fontSize: 11 }} />
                <Tooltip />
                <Legend />
                <Bar yAxisId="pct"   dataKey="overall_osa_pct"    name="OSA %"       fill="#3b82f6" radius={[4,4,0,0]} />
                <Bar yAxisId="pct"   dataKey="avg_discount_pct"   name="Avg Disc %"  fill="#f59e0b" radius={[4,4,0,0]} />
                <Bar yAxisId="price" dataKey="avg_sp"             name="Avg SP (₹)"  fill="#10b981" radius={[4,4,0,0]} />
              </BarChart>
            </ResponsiveContainer>
          </div>
        )}

        {/* Top brands by OSA */}
        {topBrands.length > 0 && (
          <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
            <h2 className="section-title">Top 10 Brands by OSA</h2>
            <div className="overflow-auto max-h-56">
              <table className="data-table">
                <thead>
                  <tr>
                    <th>#</th>
                    <th>Brand</th>
                    <th>Platform</th>
                    <th>OSA %</th>
                    <th>SKUs</th>
                  </tr>
                </thead>
                <tbody>
                  {topBrands.slice(0, 10).map((r, i) => (
                    <tr key={`${r.platform}-${r.brand}`}>
                      <td className="text-slate-400 w-8">{i + 1}</td>
                      <td className="font-medium">{r.brand}</td>
                      <td><span className="badge badge-blue">{r.platform}</span></td>
                      <td>
                        <span className={`font-semibold ${r.osa_pct >= 80 ? 'text-emerald-600' : r.osa_pct >= 60 ? 'text-amber-600' : 'text-red-600'}`}>
                          {r.osa_pct}%
                        </span>
                      </td>
                      <td>{r.skus}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}
      </div>

      {/* Platform details table */}
      {platforms.length > 0 && (
        <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
          <h2 className="section-title">Platform Details</h2>
          <div className="overflow-x-auto">
            <table className="data-table">
              <thead>
                <tr>
                  <th>Platform</th>
                  <th>SKUs</th>
                  <th>Brands</th>
                  <th>Cities</th>
                  <th>Stores</th>
                  <th>OSA %</th>
                  <th>Avg MRP</th>
                  <th>Avg SP</th>
                  <th>Avg Disc %</th>
                  <th>Avg Position</th>
                  <th>Last Obs</th>
                </tr>
              </thead>
              <tbody>
                {platforms.map(r => (
                  <tr key={r.platform}>
                    <td className="font-semibold capitalize">{r.platform}</td>
                    <td>{r.total_skus?.toLocaleString()}</td>
                    <td>{r.total_brands}</td>
                    <td>{r.total_cities}</td>
                    <td>{r.total_stores?.toLocaleString()}</td>
                    <td>
                      <span className={r.overall_osa_pct >= 80 ? 'text-emerald-600 font-semibold' : r.overall_osa_pct >= 60 ? 'text-amber-600 font-semibold' : 'text-red-600 font-semibold'}>
                        {r.overall_osa_pct}%
                      </span>
                    </td>
                    <td>{r.avg_mrp ? `₹${r.avg_mrp}` : '—'}</td>
                    <td>{r.avg_sp ? `₹${r.avg_sp}` : '—'}</td>
                    <td>{r.avg_discount_pct != null ? `${r.avg_discount_pct}%` : '—'}</td>
                    <td>{r.avg_shelf_position ?? '—'}</td>
                    <td className="text-slate-400 text-xs">{r.last_observation_at ? format(new Date(r.last_observation_at), 'dd MMM HH:mm') : '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}
