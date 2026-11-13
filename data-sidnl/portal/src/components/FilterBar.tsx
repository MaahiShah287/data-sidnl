import Link from 'next/link';
import clsx from 'clsx';

type Opt = { value: string | null; label: string };

/** Query-string pill filter (server component: plain links, no client JS).
 *  `current` = the active value of `param`; every other param in `keep` is preserved. */
export function Pills({ base, param, options, current, keep }: {
  base: string; param: string; options: Opt[]; current: string | null; keep: Record<string, string | null | undefined>;
}) {
  const href = (v: string | null) => {
    const u = new URLSearchParams();
    Object.entries({ ...keep, [param]: v }).forEach(([k, val]) => { if (val) u.set(k, val); });
    const s = u.toString();
    return s ? `${base}?${s}` : base;
  };
  return (
    <div className="flex flex-wrap items-center gap-1">
      {options.map(o => (
        <Link key={o.label} href={href(o.value)}
          className={clsx('px-2.5 py-1 rounded-full text-xs border',
            (current ?? null) === o.value
              ? 'bg-blue-600 border-blue-600 text-white'
              : 'bg-white border-slate-200 text-slate-600 hover:bg-slate-50')}>
          {o.label}
        </Link>
      ))}
    </div>
  );
}

/** Platform (+ optional brand) filter bar shared by the pages. */
export default function FilterBar({ base, platform, brand, brands, platforms = ['blinkit', 'zepto'], allPlatforms = true, keep = {} }: {
  base: string;
  platform: string | null;
  brand?: string | null;
  brands?: { brand_key: string; brand_name: string }[];
  platforms?: string[];
  allPlatforms?: boolean;
  keep?: Record<string, string | null | undefined>;
}) {
  const pOpts: Opt[] = [
    ...(allPlatforms ? [{ value: null, label: 'All platforms' }] : []),
    ...platforms.map(p => ({ value: p, label: p[0].toUpperCase() + p.slice(1) })),
  ];
  return (
    <div className="flex flex-wrap items-center gap-x-6 gap-y-2 text-xs text-slate-500">
      <div className="flex items-center gap-2">
        <span>Platform</span>
        <Pills base={base} param="platform" options={pOpts} current={platform} keep={{ ...keep, brand }} />
      </div>
      {brands && brands.length > 0 && (
        <div className="flex items-center gap-2">
          <span>Brand</span>
          <Pills base={base} param="brand"
            options={[{ value: null, label: 'All' }, ...brands.map(b => ({ value: b.brand_key, label: b.brand_name }))]}
            current={brand ?? null} keep={{ ...keep, platform }} />
        </div>
      )}
    </div>
  );
}
