'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import {
  LayoutDashboard, TrendingUp, Tag, CheckCircle,
  Eye, Swords, Megaphone, ListChecks, ShoppingCart, Truck, Receipt
} from 'lucide-react';
import clsx from 'clsx';

const NAV = [
  { href: '/',              label: 'Overview',        icon: LayoutDashboard },
  { href: '/availability', label: 'Availability',    icon: CheckCircle },
  { href: '/pricing',      label: 'Pricing',         icon: Tag },
  { href: '/visibility',   label: 'Visibility',      icon: Eye },
  { href: '/competitors',  label: 'Competitors',     icon: Swords },
  { href: '/sales',        label: 'Sales',           icon: ShoppingCart },
  { href: '/supply',       label: 'Supply',          icon: Truck },
  { href: '/finance',      label: 'Finance',         icon: Receipt },
  { href: '/ads',          label: 'Ads',             icon: Megaphone },
  { href: '/metrics',      label: 'Metric coverage', icon: ListChecks },
];

export default function Sidebar() {
  const path = usePathname();
  return (
    <aside className="w-56 shrink-0 bg-white border-r border-slate-200 flex flex-col">
      {/* Logo */}
      <div className="px-5 py-4 border-b border-slate-200">
        <div className="flex items-center gap-2">
          <TrendingUp className="w-5 h-5 text-blue-600" />
          <span className="font-bold text-slate-800 text-sm">SIDNL Analytics</span>
        </div>
        <p className="text-xs text-slate-400 mt-0.5">Silver → Dash · Live</p>
      </div>

      {/* Nav */}
      <nav className="flex-1 px-3 py-4 space-y-0.5 overflow-y-auto">
        {NAV.map(({ href, label, icon: Icon }) => (
          <Link
            key={href}
            href={href}
            className={clsx('nav-link', path === href && 'active')}
          >
            <Icon className="w-4 h-4 shrink-0" />
            <span>{label}</span>
          </Link>
        ))}
      </nav>

      {/* Footer */}
      <div className="px-5 py-3 border-t border-slate-200">
        <p className="text-xs text-slate-400">
          Data: Blinkit · Zepto<br />
          © 2026 SIDNL
        </p>
      </div>
    </aside>
  );
}
