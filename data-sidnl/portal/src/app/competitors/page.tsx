import KpiCard from '@/components/KpiCard';
import Header, { Empty } from '@/components/Header';
import FilterBar, { Pills } from '@/components/FilterBar';
import { Trend } from '@/components/Charts';
import { qSafe, pct, n, osaColor, SP, pickPlatform, pickBrand, pickParam } from '@/lib/db';

export const dynamic = 'force-dynamic';

const MIGRATION_HINT =
  'The competitor tables (dash.comp_*) are missing - dash_013 was applied on 2026-11-13; check sql/rollbacks.sql was not run. See docs/ARCHITECTURE.md section 5b.';

type Row = {
  brand_key: string; brand_name: string; is_client: boolean;
  cards: number; category_cards: number; skus: number; stores_listed: number; stores_scanned: number;
  top10_cards: number; organic_cards: number; ad_cards: number; rank_sum: number | null; rank_n: number | null;
  in_stock_obs: number; valid_obs: number;
  share: number | null; avg_rank: number | null; top10: number | null; paid: number | null; osa: number | null;
  listing: number | null; disc: number | null; avg_sp: number | null; p100: number | null; unit: string | null;
};

export default async function CompetitorsPage({ searchParams }: { searchParams?: SP }) {
  const platform = pickPlatform(searchParams) ?? 'blinkit';
  const cityParam = pickParam(searchParams, 'city') ?? 'ALL';
  const catParam = pickParam(searchParams, 'category');
  const focalParam = pickBrand(searchParams);
  const base = '/competitors';

  // 1) which categories exist for this platform (a category is in scope when a client brand is on its shelf)
  const cats = await qSafe<{ l2_id: string; category_name: string; last_day: string; focal_cards: number }>(
    `select l2_id, coalesce(category_name, l2_id) category_name, max(obs_date)::text last_day,
            coalesce(sum(cards) filter (where is_client and city_slug = 'ALL'), 0)::int focal_cards
       from dash.comp_brand_day where platform = $1 group by 1, 2 order by 4 desc, 2`, [platform]);

  const head = (
    <>
      <Header title="Competitors" subtitle="Shelf share, rank, OSA, discount and price vs competing brands (scraped category shelves)" />
      <FilterBar base={base} platform={platform} allPlatforms={false} keep={{ category: null, city: null }} />
    </>
  );

  if (cats.error) {
    return (
      <div className="space-y-6">
        {head}
        <Empty what={`${MIGRATION_HINT} (${cats.error.slice(0, 160)})`} />
      </div>
    );
  }
  if (!cats.rows.length) {
    return (
      <div className="space-y-6">
        {head}
        <Empty what={`No competitor data for ${platform} yet. A category shelf where a client brand is listed must be scraped and loaded into silver first${
          platform === 'zepto' ? ' (Zepto: its "Veg Snacks" shelf is loaded by the silver pipeline; the competitor tables refresh every 10 minutes)' : ''}.`} />
      </div>
    );
  }

  const cat = cats.rows.find(c => c.l2_id === catParam) ?? cats.rows[0];

  // 2) client brands present on this shelf; the focal brand is the one compared against everybody else
  const focals = await qSafe<{ brand_key: string; brand_name: string }>(
    `select distinct brand_key, brand_name from dash.comp_brand_day where platform = $1 and l2_id = $2 and is_client order by 2`,
    [platform, cat.l2_id]);
  const focal = focals.rows.find(b => b.brand_key === focalParam)
    ?? focals.rows.find(b => b.brand_key === 'mr munchies') ?? focals.rows[0];

  const day = (await qSafe<{ d: string }>(
    `select max(obs_date)::text d from dash.comp_brand_day where platform = $1 and l2_id = $2`, [platform, cat.l2_id])).rows[0]?.d;
  const cities = (await qSafe<{ city_slug: string; n: number }>(
    `select city_slug, count(*)::int n from dash.comp_brand_day where platform = $1 and l2_id = $2 and obs_date = $3 group by 1
      order by (city_slug = 'ALL') desc, 1`, [platform, cat.l2_id, day])).rows;
  const city = cities.find(c => c.city_slug === cityParam)?.city_slug ?? 'ALL';

  const keep = { platform, category: cat.l2_id, city, brand: focal?.brand_key ?? null };

  const [board, trend, skus, moves, cross, cityRows] = await Promise.all([
    qSafe<Row>(
      `select brand_key, brand_name, is_client, cards, category_cards, skus, stores_listed, stores_scanned, top10_cards,
              organic_cards, ad_cards, rank_sum::float8, rank_n, in_stock_obs, valid_obs,
              share_of_shelf_pct::float8 share, avg_rank::float8, top10_rate_pct::float8 top10, paid_share_pct::float8 paid,
              osa_pct::float8 osa, listing_pct::float8 listing, avg_discount_pct::float8 disc, avg_sp::float8,
              median_price_per_100::float8 p100, price_unit unit
         from dash.comp_brand_day
        where platform = $1 and l2_id = $2 and obs_date = $3 and city_slug = $4
        order by share_of_shelf_pct desc nulls last`, [platform, cat.l2_id, day, city]),
    qSafe(
      `select obs_date::text d, share_of_shelf_pct::float8 share, osa_pct::float8 osa, listing_pct::float8 listing
         from dash.comp_brand_day where platform = $1 and l2_id = $2 and brand_key = $3 and city_slug = $4 order by 1`,
      [platform, cat.l2_id, focal?.brand_key ?? '', city]),
    qSafe(
      `select product_name, pack_raw, sidnl_id,
              sum(in_stock_obs)::float8 / nullif(sum(valid_obs), 0) * 100 osa,
              sum(stores_listed)::int stores,
              (percentile_cont(0.5) within group (order by sp_median))::float8 sp,
              (percentile_cont(0.5) within group (order by mrp_median))::float8 mrp,
              avg(discount_pct)::float8 disc,
              (percentile_cont(0.5) within group (order by price_per_100))::float8 p100, max(price_unit) unit,
              avg(avg_rank)::float8 rnk, avg(sp_change_pct)::float8 chg
         from dash.v_comp_sku_day
        where platform = $1 and l2_id = $2 and obs_date = $3 and brand_key = $4 and ($5 = 'ALL' or city_slug = $5)
        group by product_key, product_name, pack_raw, sidnl_id order by product_name`,
      [platform, cat.l2_id, day, focal?.brand_key ?? '', city]),
    qSafe(
      `select brand_name, product_name, pack_raw, city_slug, prior_obs_date::text prior_day, prior_sp::float8 prior_sp,
              sp_median::float8 sp, sp_change_pct::float8 chg
         from dash.comp_sku_day
        where platform = $1 and l2_id = $2 and obs_date = $3 and not is_client and sp_change_pct is not null
          and sp_change_pct <> 0 and ($4 = 'ALL' or city_slug = $4)
        order by abs(sp_change_pct) desc limit 40`, [platform, cat.l2_id, day, city]),
    qSafe(
      `select brand_name, product_name, pack_raw, city_slug, min_sp::float8, max_sp::float8, price_gap_pct::float8 gap,
              cheapest_platform, dearest_platform
         from dash.v_comp_cross_marketplace where ($1 = 'ALL' or city_slug = $1)
        order by price_gap_pct desc nulls last limit 15`, [city]),
    qSafe(
      `select city_slug, share_of_shelf_pct::float8 share, osa_pct::float8 osa, listing_pct::float8 listing,
              avg_discount_pct::float8 disc, avg_sp::float8, avg_rank::float8, cards, category_cards
         from dash.comp_brand_day
        where platform = $1 and l2_id = $2 and obs_date = $3 and brand_key = $4 and city_slug <> 'ALL'
        order by share_of_shelf_pct desc nulls last`, [platform, cat.l2_id, day, focal?.brand_key ?? '']),
  ]);

  const rows = board.rows;
  const me = rows.find(r => r.brand_key === focal?.brand_key);
  const rank = me ? rows.findIndex(r => r.brand_key === me.brand_key) + 1 : null;
  // category benchmark OSA = SUM(in stock) / SUM(valid) over every brand (never the average of percentages)
  const catOsa = (() => {
    const a = rows.reduce((s, r) => s + (r.in_stock_obs ?? 0), 0), b = rows.reduce((s, r) => s + (r.valid_obs ?? 0), 0);
    return b ? (a / b) * 100 : null;
  })();

  // price gap of the focal brand to each competitor (normalised unit price, same unit only)
  const gaps = me?.p100 != null
    ? rows.filter(r => r.brand_key !== me.brand_key && r.p100 != null && r.unit === me.unit)
        .map(r => ({
          brand: r.brand_name, client: r.is_client, comp: r.p100 as number,
          gap: (me.p100 as number) - (r.p100 as number),
          gapPct: (((me.p100 as number) - (r.p100 as number)) / (r.p100 as number)) * 100,
          index: ((me.p100 as number) / (r.p100 as number)) * 100,
        })).sort((x, y) => Math.abs(y.gapPct) - Math.abs(x.gapPct))
    : [];
  const BAND = 10; // +/- % treated as "at parity" (handbook asks the owner to confirm the band)
  const parity = gaps.length ? Math.max(0, 100 - gaps.reduce((s, g) => s + Math.abs(g.gapPct), 0) / gaps.length) : null;
  const outside = gaps.filter(g => Math.abs(g.gapPct) > BAND).length;
  const medianComp = (() => {
    const v = gaps.map(g => g.comp).sort((a, b) => a - b);
    if (!v.length) return null;
    const m = Math.floor(v.length / 2);
    return v.length % 2 ? v[m] : (v[m - 1] + v[m]) / 2;
  })();

  const up = moves.rows.filter((r: any) => r.chg > 0).slice(0, 8);
  const down = moves.rows.filter((r: any) => r.chg < 0).slice(0, 8);
  const tip = (num: number | null | undefined, den: number | null | undefined) => (num != null && den != null ? `${num} / ${den}` : undefined);

  return (
    <div className="space-y-6">
      {head}

      <div className="flex flex-wrap items-center gap-x-6 gap-y-2 text-xs text-slate-500">
        <div className="flex items-center gap-2"><span>Category</span>
          <Pills base={base} param="category" current={cat.l2_id}
            options={cats.rows.map(c => ({ value: c.l2_id, label: c.category_name }))} keep={{ ...keep }} /></div>
        {focals.rows.length > 0 && <div className="flex items-center gap-2"><span>Compare brand</span>
          <Pills base={base} param="brand" current={focal?.brand_key ?? null}
            options={focals.rows.map(b => ({ value: b.brand_key, label: b.brand_name }))} keep={{ ...keep }} /></div>}
        <div className="flex items-center gap-2"><span>City</span>
          <Pills base={base} param="city" current={city}
            options={cities.map(c => ({ value: c.city_slug, label: c.city_slug === 'ALL' ? 'All cities' : c.city_slug }))}
            keep={{ ...keep }} /></div>
      </div>
      <p className="text-xs text-slate-500">
        {platform} · {cat.category_name} · scraped {day ?? '—'} · {rows.length} brands on the shelf. Share of shelf is a
        <b> proxy</b> for share of voice / market share (no sales feed); price gaps compare normalised unit prices at brand level.
      </p>

      {!focal || !me ? (
        <Empty what="The selected brand has no shelf rows for this city/day." />
      ) : (
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          <KpiCard title="Share of shelf (proxy)" value={pct(me.share)} subtitle={`#${rank} of ${rows.length} brands · ${me.cards}/${me.category_cards} cards`} />
          <KpiCard title="Avg shelf rank" value={n(me.avg_rank)} subtitle="lower is better" />
          <KpiCard title="Shelf OSA" value={pct(me.osa)} subtitle={`category ${pct(catOsa)}`} />
          <KpiCard title="Store listing" value={pct(me.listing)} subtitle={`${me.stores_listed}/${me.stores_scanned} stores`} />
          <KpiCard title="Avg discount" value={pct(me.disc)} />
          <KpiCard title="Median price / 100 g" value={me.p100 != null ? `₹${n(me.p100)}` : '—'}
                   subtitle={medianComp != null ? `competitor median ₹${n(medianComp)}` : undefined} />
          <KpiCard title="Price parity score" value={parity != null ? n(parity, 0) : '—'} subtitle={`${outside} of ${gaps.length} brands outside ±${BAND}%`} />
          <KpiCard title="Top-10 rate" value={pct(me.top10)} subtitle={`${me.top10_cards}/${me.organic_cards} organic cards`} />
        </div>
      )}

      {trend.rows.length > 1 && (
        <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
          <h2 className="section-title">{focal?.brand_name} · share of shelf, OSA and listing by day ({city === 'ALL' ? 'all cities' : city})</h2>
          <Trend data={trend.rows} x="d" series={['share', 'osa', 'listing']} />
        </div>
      )}

      <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
        <h2 className="section-title">Brand leaderboard · {city === 'ALL' ? 'all cities' : city} · {day}</h2>
        <div className="overflow-x-auto">
          <table className="data-table">
            <thead><tr>
              <th>#</th><th>Brand</th><th>Share of shelf</th><th>Avg rank</th><th>Top-10 rate</th><th>Paid share</th>
              <th>OSA</th><th>Store listing</th><th>SKUs</th><th>Avg discount</th><th>Avg SP</th><th>₹ / 100 g</th>
            </tr></thead>
            <tbody>
              {rows.map((r, i) => (
                <tr key={r.brand_key} className={r.brand_key === focal?.brand_key ? 'bg-blue-50 font-medium' : ''}>
                  <td>{i + 1}</td>
                  <td>{r.brand_name}{r.is_client ? ' ★' : ''}</td>
                  <td title={tip(r.cards, r.category_cards)}>{pct(r.share)}</td>
                  <td>{n(r.avg_rank)}</td>
                  <td title={tip(r.top10_cards, r.organic_cards)}>{pct(r.top10)}</td>
                  <td title={tip(r.ad_cards, r.cards)}>{pct(r.paid)}</td>
                  <td className={osaColor(r.osa)} title={tip(r.in_stock_obs, r.valid_obs)}>{pct(r.osa)}</td>
                  <td title={tip(r.stores_listed, r.stores_scanned)}>{pct(r.listing)}</td>
                  <td>{r.skus}</td>
                  <td>{pct(r.disc)}</td>
                  <td>{r.avg_sp != null ? `₹${n(r.avg_sp)}` : '—'}</td>
                  <td>{r.p100 != null ? `₹${n(r.p100)}` : '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className="mt-2 text-xs text-slate-500">★ client brand. Hover a % to see its numerator / denominator. Percentages are ratios of sums.</p>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
          <h2 className="section-title">Price gap: {focal?.brand_name ?? '—'} vs competitors (₹ per 100 {me?.unit ?? 'g'})</h2>
          {gaps.length === 0 ? <Empty what="No comparable unit prices (needs g/ml pack sizes on both brands)." /> : (
            <div className="overflow-auto max-h-96">
              <table className="data-table">
                <thead><tr><th>Competitor</th><th>Their ₹/100</th><th>Gap ₹</th><th>Gap %</th><th>Price index</th></tr></thead>
                <tbody>{gaps.map(g => (
                  <tr key={g.brand}>
                    <td>{g.brand}{g.client ? ' ★' : ''}</td><td>₹{n(g.comp)}</td>
                    <td className={g.gap > 0 ? 'text-red-600' : 'text-emerald-600'}>{g.gap > 0 ? '+' : ''}{n(g.gap)}</td>
                    <td>{g.gapPct > 0 ? '+' : ''}{n(g.gapPct)}%</td><td>{n(g.index, 0)}</td>
                  </tr>))}</tbody>
              </table>
            </div>
          )}
          <p className="mt-2 text-xs text-slate-500">Index &gt; 100 = {focal?.brand_name ?? 'the brand'} is dearer. Brand-level proxy (median SKU unit prices) until a verified SKU match table exists.</p>
        </div>

        <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
          <h2 className="section-title">{focal?.brand_name ?? '—'} by SKU · {city === 'ALL' ? 'all cities' : city}</h2>
          {skus.rows.length === 0 ? <Empty what="No SKU rows." /> : (
            <div className="overflow-auto max-h-96">
              <table className="data-table">
                <thead><tr><th>SKU</th><th>Pack</th><th>SP</th><th>MRP</th><th>Disc</th><th>₹/100</th><th>OSA</th><th>Stores</th><th>Δ SP</th></tr></thead>
                <tbody>{skus.rows.map((r: any) => (
                  <tr key={r.sidnl_id ?? r.product_name}>
                    <td>{r.product_name}</td><td>{r.pack_raw}</td><td>₹{n(r.sp)}</td><td>₹{n(r.mrp)}</td>
                    <td>{pct(r.disc)}</td><td>{r.p100 != null ? `₹${n(r.p100)}` : '—'}</td>
                    <td className={osaColor(r.osa)}>{pct(r.osa)}</td><td>{r.stores}</td>
                    <td>{r.chg != null ? pct(r.chg) : '—'}</td>
                  </tr>))}</tbody>
              </table>
            </div>
          )}
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {[{ t: 'Competitor price increases (vs previous scrape)', r: up }, { t: 'Competitor price decreases (vs previous scrape)', r: down }].map(({ t, r }) => (
          <div key={t} className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
            <h2 className="section-title">{t}</h2>
            {r.length === 0 ? <Empty what="No competitor price changes between the last two scrapes." /> : (
              <table className="data-table">
                <thead><tr><th>Brand</th><th>SKU</th><th>City</th><th>Was</th><th>Now</th><th>Δ%</th></tr></thead>
                <tbody>{r.map((x: any, i: number) => (
                  <tr key={i}><td>{x.brand_name}</td><td>{x.product_name} {x.pack_raw}</td><td>{x.city_slug}</td>
                    <td>₹{n(x.prior_sp)}</td><td>₹{n(x.sp)}</td>
                    <td className={x.chg > 0 ? 'text-red-600' : 'text-emerald-600'}>{pct(x.chg)}</td></tr>))}</tbody>
              </table>
            )}
            <p className="mt-2 text-xs text-slate-500">Changes reflect scrape intervals, not exact change times.</p>
          </div>
        ))}
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
          <h2 className="section-title">{focal?.brand_name ?? '—'} by city (latest day)</h2>
          {cityRows.rows.length === 0 ? <Empty what="No city rows." /> : (
            <div className="overflow-auto max-h-96">
              <table className="data-table">
                <thead><tr><th>City</th><th>Share</th><th>Avg rank</th><th>OSA</th><th>Listing</th><th>Disc</th><th>Avg SP</th></tr></thead>
                <tbody>{cityRows.rows.map((r: any) => (
                  <tr key={r.city_slug}><td>{r.city_slug}</td><td title={tip(r.cards, r.category_cards)}>{pct(r.share)}</td>
                    <td>{n(r.avg_rank)}</td><td className={osaColor(r.osa)}>{pct(r.osa)}</td><td>{pct(r.listing)}</td>
                    <td>{pct(r.disc)}</td><td>₹{n(r.avg_sp)}</td></tr>))}</tbody>
              </table>
            </div>
          )}
        </div>

        <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
          <h2 className="section-title">Cross-marketplace price gap (same SI id on Blinkit and Zepto)</h2>
          {cross.error ? <Empty what={MIGRATION_HINT} /> : cross.rows.length === 0 ? (
            <Empty what="No product is listed on two platforms with exactly the same brand, name and pack yet (needs the same product on both platforms with identical brand, name and pack)." />
          ) : (
            <div className="overflow-auto max-h-96">
              <table className="data-table">
                <thead><tr><th>SKU</th><th>City</th><th>Min</th><th>Max</th><th>Gap %</th><th>Cheaper on</th></tr></thead>
                <tbody>{cross.rows.map((r: any, i: number) => (
                  <tr key={i}><td>{r.product_name} {r.pack_raw}</td><td>{r.city_slug}</td><td>₹{n(r.min_sp)}</td><td>₹{n(r.max_sp)}</td>
                    <td>{pct(r.gap)}</td><td className="capitalize">{r.cheapest_platform}</td></tr>))}</tbody>
              </table>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
