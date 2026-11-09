'use client';
import {
  BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, Legend,
  LineChart, Line, ResponsiveContainer,
} from 'recharts';

const COLORS = ['#3b82f6', '#10b981', '#f59e0b', '#ef4444', '#8b5cf6', '#06b6d4'];

export function HBar({ data, label, value, suffix = '%', max }: {
  data: any[]; label: string; value: string; suffix?: string; max?: number;
}) {
  return (
    <ResponsiveContainer width="100%" height={Math.max(220, data.length * 26)}>
      <BarChart data={data} layout="vertical" margin={{ left: 90, right: 20 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
        <XAxis type="number" domain={max ? [0, max] : undefined} tick={{ fontSize: 11 }} tickFormatter={v => `${v}${suffix}`} />
        <YAxis type="category" dataKey={label} tick={{ fontSize: 11 }} width={90} />
        <Tooltip formatter={(v: any) => [`${Number(v).toFixed(1)}${suffix}`, value]} />
        <Bar dataKey={value} fill="#3b82f6" radius={[0, 4, 4, 0]} />
      </BarChart>
    </ResponsiveContainer>
  );
}

export function Trend({ data, x, series, suffix = '%' }: {
  data: any[]; x: string; series: string[]; suffix?: string;
}) {
  return (
    <ResponsiveContainer width="100%" height={260}>
      <LineChart data={data} margin={{ left: 0, right: 20 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
        <XAxis dataKey={x} tick={{ fontSize: 11 }} />
        <YAxis tick={{ fontSize: 11 }} tickFormatter={v => `${v}${suffix}`} />
        <Tooltip formatter={(v: any) => `${Number(v).toFixed(1)}${suffix}`} />
        <Legend />
        {series.map((s, i) => (
          <Line key={s} type="monotone" dataKey={s} stroke={COLORS[i % COLORS.length]} strokeWidth={2} dot connectNulls />
        ))}
      </LineChart>
    </ResponsiveContainer>
  );
}
