'use client';
import { ReactNode } from 'react';
import clsx from 'clsx';

interface KpiCardProps {
  title: string;
  value: string | number | null | undefined;
  subtitle?: string;
  trend?: 'up' | 'down' | 'neutral';
  unit?: string;
  badge?: string;
  badgeColor?: 'green' | 'red' | 'yellow' | 'blue' | 'gray';
  icon?: ReactNode;
  loading?: boolean;
  unavailable?: boolean;
}

export default function KpiCard({
  title, value, subtitle, unit, badge, badgeColor = 'gray',
  icon, loading, unavailable
}: KpiCardProps) {
  return (
    <div className="kpi-card">
      <div className="flex items-start justify-between">
        <p className="text-xs font-medium text-slate-500 uppercase tracking-wider">{title}</p>
        {icon && <span className="text-slate-400">{icon}</span>}
      </div>

      {loading ? (
        <div className="mt-2 h-7 w-24 bg-slate-100 animate-pulse rounded" />
      ) : unavailable ? (
        <p className="mt-2 text-sm text-slate-400 italic">Not available</p>
      ) : (
        <div className="mt-2 flex items-baseline gap-1">
          <span className="text-2xl font-bold text-slate-900">
            {value ?? '—'}
          </span>
          {unit && <span className="text-sm text-slate-500">{unit}</span>}
        </div>
      )}

      <div className="mt-2 flex items-center gap-2">
        {badge && (
          <span className={clsx('badge', `badge-${badgeColor}`)}>{badge}</span>
        )}
        {subtitle && (
          <p className="text-xs text-slate-500 truncate">{subtitle}</p>
        )}
      </div>
    </div>
  );
}
