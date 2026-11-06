'use client';
import { useState, useEffect, useCallback } from 'react';
import { createClient } from '@/lib/supabase';
import KpiCard from '@/components/KpiCard';
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer, ScatterChart, Scatter } from 'recharts';

export default function PricingPage() {
  const supabase = createClient();
  const [current, setCurrent] = useState<any[]>([]);
  const [parity, setParity] = useState<any[]>([]);
  const [daily, setDaily] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true); setError(null);
    try {
      const [cRes, pRes, dRes] = await Promise.all([
        supabase.from('v_price_current').select('platform,product_name,brand,l1_category,l2_category,city_slug,mrp,sale_price,discount_pct,discount_amount,availability').schema('gold').limit(200).order('discount_pct', { ascending: false }),
        supabase.from('mv_price_parity').select('*').schema('gold').order('price_gap', { ascending: false }).limit(50),
        supabase.from('mv_pricing_daily').select('obs_date,platform,brand,avg_sp,avg_mrp,avg_discount_pct,max_discount_pct').schema('gold').order('obs_date').limit(200),
      ]);
      if (cRes.error) throw cRes.error;
      setCurrent(cRes.data ?? []);
      setParity(pRes.data ?? []);
      setDaily(dRes.data ?? []);
    } catch (e: any) { setError(e.message); }
    finally { setLoading(false); }
  }, []);

  useEffect(() => { load(); }, [load]);

  const avgDiscount = current.length ? (current.reduce((s, r) => s + (r.discount_pct ?? 0), 0) / current.length).toFixed(1) : null;
  const maxDiscount = current.length ? Math.max(...current.map(r => r.discount_pct ?? 0)).toFixed(1) : null;
  const avgSp = current.length ? (current.reduce((s, r) => s + (r.sale_price ?? 0), 0) / current.length).toFixed(0) : null;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-slate-900">Pricing</h1>
        <p className="text-sm text-slate-500 mt-0.5">MRP, SP, discount %, and cross-platform price parity</p>
      </div>
      {error && <div className="bg-red-50 border border-red-200 rounded-lg p-4 text-sm text-red-700">{error}</div>}

      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <KpiCard title="Avg Selling Price"   value={avgSp ? `₹${avgSp}` : null}  loading={loading} />
        <KpiCard title="Avg Discount %"      value={avgDiscount} unit="%"          loading={loading} />
        <KpiCard title="Max Discount %"      value={maxDiscount} unit="%"          loading={loading} badge="Max" badgeColor="red" />
        <KpiCard title="Multi-platform SKUs" value={parity.length}                 loading={loading} subtitle="Listed on 2+ platforms" />
        <KpiCard title="Weighted Discount"   value={null} unavailable loading={false} subtitle="No quantity data" />
        <KpiCard title="Sales Value at MRP"  value={null} unavailable loading={false} subtitle="No transaction data" />
      </div>

      {/* Price parity table */}
      {parity.length > 0 && (
        <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
          <h2 className="section-title">Cross-Platform Price Parity</h2>
          <div className="overflow-x-auto">
            <table className="data-table">
              <thead>
                <tr>
                  <th>Product</th>
                  <th>Brand</th>
                  <th>Platforms</th>
                  <th>Min SP</th>
                  <th>Max SP</th>
                  <th>Price Gap</th>
                  <th>Cheapest Platform</th>
                </tr>
              </thead>
              <tbody>
                {parity.slice(0, 30).map((r, i) => (
                  <tr key={i}>
                    <td className="font-medium max-w-xs truncate">{r.product_name}</td>
                    <td>{r.brand}</td>
                    <td>{r.platforms}</td>
                    <td className="text-emerald-600 font-semibold">₹{r.min_sp_cross_platform}</td>
                    <td className="text-red-600">₹{r.max_sp_cross_platform}</td>
                    <td className={r.sp_spread > 20 ? 'text-red-600 font-semibold' : 'text-slate-700'}>
                      ₹{r.sp_spread}
                    </td>
                    <td><span className="badge badge-blue capitalize">{r.cheapest_platform}</span></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* Top discounts table */}
      {current.length > 0 && (
        <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
          <h2 className="section-title">Products with Highest Discounts</h2>
          <div className="overflow-x-auto">
            <table className="data-table">
              <thead>
                <tr>
                  <th>Product</th>
                  <th>Brand</th>
                  <th>Category</th>
                  <th>Platform</th>
                  <th>MRP</th>
                  <th>SP</th>
                  <th>Discount %</th>
                  <th>Discount ₹</th>
                </tr>
              </thead>
              <tbody>
                {current.slice(0, 20).map((r, i) => (
                  <tr key={i}>
                    <td className="font-medium max-w-xs truncate">{r.product_name}</td>
                    <td>{r.brand}</td>
                    <td>{r.l2_category}</td>
                    <td><span className="badge badge-blue">{r.platform}</span></td>
                    <td>₹{r.mrp}</td>
                    <td>₹{r.sale_price}</td>
                    <td className="font-semibold text-amber-600">{r.discount_pct}%</td>
                    <td>₹{r.discount_amount}</td>
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
