'use client';
import { useState, useEffect, useCallback } from 'react';
import { createClient } from '@/lib/supabase';
import KpiCard from '@/components/KpiCard';
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer } from 'recharts';
import { format } from 'date-fns';

export default function AvailabilityPage() {
  const supabase = createClient();
  const [dMinus, setDMinus] = useState<any[]>([]);
  const [daily, setDaily] = useState<any[]>([]);
  const [brandOsa, setBrandOsa] = useState<any[]>([]);
  const [catOsa, setCatOsa] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true); setError(null);
    try {
      const [dRes, dlyRes, brRes, catRes] = await Promise.all([
        supabase.from('v_osa_d_minus').select('*').schema('gold'),
        supabase.from('mv_osa_daily').select('obs_date,platform,brand,l1_category,city_slug,total_obs,available_obs,osa_pct').schema('gold')
          .order('obs_date', { ascending: false }).limit(200),
        supabase.from('mv_brand_daily').select('obs_date,platform,brand,osa_pct,total_obs,available_obs').schema('gold')
          .order('osa_pct', { ascending: false }).limit(50),
        supabase.from('mv_category_daily').select('obs_date,platform,l1_category,l2_category,osa_pct,total_obs,distinct_skus').schema('gold')
          .order('osa_pct', { ascending: false }).limit(50),
      ]);
      if (dRes.error) throw dRes.error;
      setDMinus(dRes.data ?? []);
      setDaily(dlyRes.data ?? []);
      setBrandOsa(brRes.data ?? []);
      setCatOsa(catRes.data ?? []);
    } catch (e: any) { setError(e.message); }
    finally { setLoading(false); }
  }, []);

  useEffect(() => { load(); }, [load]);

  // aggregate d-minus across all cities (weighted)
  const dm = dMinus.reduce((acc, r) => ({
    d1: acc.d1 == null ? r.osa_d1_pct : ((acc.d1 + r.osa_d1_pct) / 2),
    d2: acc.d2 == null ? r.osa_d2_pct : ((acc.d2 + r.osa_d2_pct) / 2),
    d3: acc.d3 == null ? r.osa_d3_pct : ((acc.d3 + r.osa_d3_pct) / 2),
    latest: r.latest_date,
  }), {} as any);

  const osaColor = (v: number) => v >= 80 ? 'text-emerald-600' : v >= 60 ? 'text-amber-600' : 'text-red-600';

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-slate-900">Availability</h1>
        <p className="text-sm text-slate-500 mt-0.5">OSA, D-1/D-2/D-3, brand and category breakdown</p>
      </div>
      {error && <div className="bg-red-50 border border-red-200 rounded-lg p-4 text-sm text-red-700">{error}</div>}

      {/* D-minus KPIs */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <KpiCard title="OSA D-1 (yesterday)" value={dm.d1 != null ? `${dm.d1?.toFixed(1)}%` : null} loading={loading}
          badge={dm.d1 >= 80 ? 'Good' : dm.d1 >= 60 ? 'Watch' : 'Poor'}
          badgeColor={dm.d1 >= 80 ? 'green' : dm.d1 >= 60 ? 'yellow' : 'red'} />
        <KpiCard title="OSA D-2" value={dm.d2 != null ? `${dm.d2?.toFixed(1)}%` : null} loading={loading} />
        <KpiCard title="OSA D-3" value={dm.d3 != null ? `${dm.d3?.toFixed(1)}%` : null} loading={loading} />
        <KpiCard title="Data reference date" value={dm.latest ?? '—'} loading={loading} />
      </div>

      {/* OSA by platform × city */}
      {dMinus.length > 0 && (
        <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
          <h2 className="section-title">OSA D-1/D-2/D-3 by Platform × City</h2>
          <div className="overflow-x-auto">
            <table className="data-table">
              <thead>
                <tr>
                  <th>Platform</th>
                  <th>City</th>
                  <th>D-1</th>
                  <th>D-2</th>
                  <th>D-3</th>
                  <th>Avg 3D</th>
                </tr>
              </thead>
              <tbody>
                {dMinus.map(r => (
                  <tr key={`${r.platform}-${r.city_slug}`}>
                    <td className="font-medium capitalize">{r.platform}</td>
                    <td>{r.city_slug}</td>
                    <td className={osaColor(r.osa_d1_pct)}>{r.osa_d1_pct}%</td>
                    <td className={osaColor(r.osa_d2_pct)}>{r.osa_d2_pct ?? '—'}</td>
                    <td className={osaColor(r.osa_d3_pct)}>{r.osa_d3_pct ?? '—'}</td>
                    <td className="font-semibold">{r.osa_avg_3d_pct ?? '—'}%</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Brand OSA */}
        {brandOsa.length > 0 && (
          <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
            <h2 className="section-title">Top Brands by OSA</h2>
            <ResponsiveContainer width="100%" height={260}>
              <BarChart data={brandOsa.slice(0, 15)} layout="vertical" margin={{ left: 80, right: 20 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
                <XAxis type="number" domain={[0, 100]} tickFormatter={v => `${v}%`} tick={{ fontSize: 11 }} />
                <YAxis type="category" dataKey="brand" tick={{ fontSize: 11 }} width={80} />
                <Tooltip formatter={(v: any) => [`${v}%`, 'OSA']} />
                <Bar dataKey="osa_pct" name="OSA %" fill="#3b82f6" radius={[0,4,4,0]} />
              </BarChart>
            </ResponsiveContainer>
          </div>
        )}

        {/* Category OSA */}
        {catOsa.length > 0 && (
          <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
            <h2 className="section-title">Category OSA</h2>
            <div className="overflow-auto max-h-72">
              <table className="data-table">
                <thead>
                  <tr>
                    <th>L1</th>
                    <th>L2</th>
                    <th>Platform</th>
                    <th>OSA %</th>
                    <th>SKUs</th>
                  </tr>
                </thead>
                <tbody>
                  {catOsa.slice(0, 20).map((r, i) => (
                    <tr key={i}>
                      <td>{r.l1_category}</td>
                      <td className="text-slate-500">{r.l2_category}</td>
                      <td><span className="badge badge-blue">{r.platform}</span></td>
                      <td className={osaColor(r.osa_pct)}>{r.osa_pct}%</td>
                      <td>{r.distinct_skus}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
