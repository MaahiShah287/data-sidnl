-- APPLIED 2026-11-09 as dash_002_refresh (version 20261109101249). Applied text = this logic, comments trimmed.
-- dash.refresh(p_visibility_days) rebuilds the three tabs that scraped data can fill today:
--   pricing, availability  : full rebuild (small: built from ~56k readings)
--   visibility             : obs_date >= today(IST) - p_visibility_days; NULL = full rebuild of ~1M shelf cards
-- overview, ads and supply have no source yet. The loader for each new feed writes to them directly.
-- Availability DRR / DOI / PSL read dash.overview and dash.pricing, so they fill in by themselves
-- once a sales feed lands.
-- Inputs are already-validated silver data: gold.v_valid_reading (dq_status='valid', non-test platforms),
-- silver.fact_store_scan (is_valid_denominator), silver.fact_shelf_position (dq_status='valid').
create or replace function dash.refresh(p_visibility_days integer default 3)
returns jsonb
language plpgsql
set search_path to 'dash', 'gold', 'silver', 'public', 'pg_temp'
as $f$
declare
  v_stats jsonb := '{}'::jsonb; n bigint;
  v_top numeric; v_tol numeric; v_crit numeric; v_hi numeric; v_med numeric; v_low numeric; v_ref text;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_vis_from date;
begin
  select coalesce(max(value) filter (where key = 'top_of_search_n'), 10),
         coalesce(max(value) filter (where key = 'parity_tolerance_pct'), 1),
         coalesce(max(value) filter (where key = 'critical_osa_pct'), 50),
         coalesce(max(value) filter (where key = 'priority_high_osa_pct'), 30),
         coalesce(max(value) filter (where key = 'priority_medium_osa_pct'), 60),
         coalesce(max(value) filter (where key = 'low_stock_fe_units'), 5),
         coalesce(max(value_text) filter (where key = 'parity_reference_platform'), 'blinkit')
    into v_top, v_tol, v_crit, v_hi, v_med, v_low, v_ref
    from gold.cfg_threshold;
  v_vis_from := case when p_visibility_days is null then '-infinity'::date else v_today - p_visibility_days end;

  -- ════════════════════════════ PRICING ════════════════════════════
  delete from dash.pricing;
  drop table if exists _dash_pr;
  create temp table _dash_pr on commit drop as
    select distinct on (v.product_key, v.store_key, v.obs_date)
           v.obs_date, v.platform, coalesce(v.city_slug, '(unknown)') as city_slug, v.store_key, x.sidnl_id,
           v.mrp, v.selling_price, d.total_content, d.size_unit, c.threshold_sp
    from gold.v_valid_reading v
    join silver.product_xref x on x.product_key = v.product_key
    join silver.dim_product d  on d.product_key = v.product_key
    left join gold.cfg_sku c   on c.platform = d.platform and c.platform_product_id = d.platform_product_id
    where v.store_key is not null and v.selling_price is not null and v.mrp > 0
    order by v.product_key, v.store_key, v.obs_date, v.observed_at desc, v.reading_key desc;

  insert into dash.pricing (obs_date, platform, city_slug, sidnl_id, stores_observed, mrp, selling_price,
         min_selling_price, max_selling_price, discount_amount, discount_pct, weighted_discount_pct,
         price_per_100g, threshold_sp)
  select obs_date, platform, city_slug, sidnl_id, count(distinct store_key),
         round(avg(mrp), 2), round(avg(selling_price), 2), min(selling_price), max(selling_price),
         round(avg(mrp - selling_price), 2),
         round(avg(100.0 * (mrp - selling_price) / mrp), 2),
         round(100.0 * sum(mrp - selling_price) / nullif(sum(mrp), 0), 2),
         round(avg(case when size_unit in ('g', 'ml') and total_content > 0 then 100.0 * selling_price / total_content end), 2),
         min(threshold_sp)
  from _dash_pr
  group by obs_date, platform, city_slug, sidnl_id;
  get diagnostics n = row_count; v_stats := v_stats || jsonb_build_object('pricing', n);

  update dash.pricing p set
         price_vs_national_pct = case when q.national_sp > 0 then round(100.0 * (p.selling_price - q.national_sp) / q.national_sp, 2) end,
         price_gap_vs_lowest_marketplace_pct =
           case when q.platforms > 1 and q.lowest_sp > 0 then round(100.0 * (p.selling_price - q.lowest_sp) / q.lowest_sp, 2) end,
         price_gap_vs_reference_pct =
           case when q.reference_sp > 0 and q.platforms > 1 then round(100.0 * (p.selling_price - q.reference_sp) / q.reference_sp, 2) end,
         is_parity_break =
           case when q.reference_sp > 0 and q.platforms > 1 then abs(100.0 * (p.selling_price - q.reference_sp) / q.reference_sp) > v_tol end,
         threshold_diff = case when p.threshold_sp is not null then p.selling_price - p.threshold_sp end,
         sp_change_pct = case when q.prev_sp > 0 then round(100.0 * (p.selling_price - q.prev_sp) / q.prev_sp, 2) end,
         discount_change_pts = p.discount_pct - q.prev_disc
  from (
    select t.obs_date, t.platform, t.city_slug, t.sidnl_id,
           n.national_sp,
           min(t.selling_price) over m as lowest_sp,
           count(*) over m as platforms,
           max(t.selling_price) filter (where t.platform = v_ref) over m as reference_sp,
           lag(t.selling_price) over h as prev_sp,
           lag(t.discount_pct) over h as prev_disc
    from dash.pricing t
    join (select obs_date, platform, sidnl_id, avg(selling_price) national_sp from _dash_pr group by 1, 2, 3) n
      on n.obs_date = t.obs_date and n.platform = t.platform and n.sidnl_id = t.sidnl_id
    window m as (partition by t.obs_date, t.city_slug, t.sidnl_id),
           h as (partition by t.platform, t.city_slug, t.sidnl_id order by t.obs_date)
  ) q
  where q.obs_date = p.obs_date and q.platform = p.platform and q.city_slug = p.city_slug and q.sidnl_id = p.sidnl_id;

  -- ════════════════════════════ AVAILABILITY ════════════════════════════
  delete from dash.availability;
  drop table if exists _dash_av;
  create temp table _dash_av on commit drop as
  with rd as (                         -- valid store readings with their SI id
    select v.obs_date, v.platform, coalesce(v.city_slug, '(unknown)') as city_slug, v.store_key, x.sidnl_id,
           v.observed_at, v.reading_key, v.is_listed, v.is_available, v.osa_eligible,
           v.stock_status, v.inventory_units, v.inventory_is_capped
    from gold.v_valid_reading v
    join silver.product_xref x on x.product_key = v.product_key
    where v.store_key is not null
  ), scan as (                         -- DS Listing denominator: latest valid brand scan per brand x store x day
    select distinct on (s.brand_key, s.store_key, (s.scanned_at at time zone 'Asia/Kolkata')::date)
           (s.scanned_at at time zone 'Asia/Kolkata')::date as obs_date, s.platform, s.brand_key, s.store_key,
           coalesce(s.city_slug, '(unknown)') as city_slug, s.snapshot_id
    from silver.fact_store_scan s
    join silver.dim_platform pl on pl.platform = s.platform and not pl.is_test
    where s.is_valid_denominator and s.store_key is not null
    order by s.brand_key, s.store_key, (s.scanned_at at time zone 'Asia/Kolkata')::date, s.scanned_at desc, s.snapshot_id desc
  ), lst as (                          -- DS Listing numerator: SKUs that scan actually showed
    select distinct f.snapshot_id, x.sidnl_id
    from silver.fact_product_reading f
    join silver.product_xref x on x.product_key = f.product_key
    where f.source_type = 'brand_search' and f.dq_status = 'valid' and f.is_listed
  ), ds as (
    select sc.obs_date, sc.platform, sc.city_slug, sc.store_key, x.sidnl_id,
           1 as dse, max(case when l.sidnl_id is not null then 1 else 0 end) as dsl
    from scan sc
    join silver.dim_product d  on d.platform = sc.platform and d.brand_key = sc.brand_key
    join silver.product_xref x on x.product_key = d.product_key
    left join lst l on l.snapshot_id = sc.snapshot_id and l.sidnl_id = x.sidnl_id
    group by 1, 2, 3, 4, 5
  ), osa as (                          -- OSA: product-page stock checks only
    select obs_date, platform, city_slug, store_key, sidnl_id,
           count(*) as oe, count(*) filter (where is_available) as oa,
           count(*) filter (where is_listed) as ole, count(*) filter (where is_listed and is_available) as ola
    from rd where osa_eligible and is_available is not null
    group by 1, 2, 3, 4, 5
  ), lat as (                          -- latest status of the day per store x SKU, any source
    select distinct on (obs_date, store_key, sidnl_id)
           obs_date, platform, city_slug, store_key, sidnl_id, observed_at, inventory_units, inventory_is_capped,
           case when is_available is not null then is_available
                when stock_status = 'in_stock' then true
                when stock_status = 'out_of_stock' then false end as avail
    from rd
    order by obs_date, store_key, sidnl_id, observed_at desc, reading_key desc
  ), k as (
    select obs_date, platform, city_slug, store_key, sidnl_id from ds
    union select obs_date, platform, city_slug, store_key, sidnl_id from osa
    union select obs_date, platform, city_slug, store_key, sidnl_id from lat
  )
  select k.obs_date, k.platform, k.city_slug, k.store_key, k.sidnl_id,
         coalesce(ds.dse, 0) as dse, coalesce(ds.dsl, 0) as dsl,
         coalesce(o.oe, 0) as oe, coalesce(o.oa, 0) as oa, coalesce(o.ole, 0) as ole, coalesce(o.ola, 0) as ola,
         case when l.avail then 1 else 0 end as ins,
         case when l.avail = false then 1 else 0 end as oos,
         case when l.avail and l.inventory_units <= v_low then 1 else 0 end as low,
         l.inventory_units as inv,
         case when l.inventory_is_capped then 1 else 0 end as cap,
         l.observed_at
  from k
  left join ds    using (obs_date, platform, city_slug, store_key, sidnl_id)
  left join osa o using (obs_date, platform, city_slug, store_key, sidnl_id)
  left join lat l using (obs_date, platform, city_slug, store_key, sidnl_id);

  -- store rows (Dark Store Map)
  insert into dash.availability (obs_date, platform, city_slug, sidnl_id, store_key,
         ds_eligible_stores, ds_listed_stores, ds_listing_pct,
         osa_eligible_obs, osa_available_obs, osa_pct, osa_in_ls_eligible_obs, osa_in_ls_available_obs, osa_in_ls_pct,
         in_stock_stores, out_of_stock_stores, low_stock_stores, inventory_fe, inventory_fe_capped_stores, last_observed_at)
  select obs_date, platform, city_slug, sidnl_id, store_key,
         dse, dsl, case when dse > 0 then round(100.0 * dsl / dse, 2) end,
         oe, oa, case when oe > 0 then round(100.0 * oa / oe, 2) end,
         ole, ola, case when ole > 0 then round(100.0 * ola / ole, 2) end,
         ins, oos, low, inv, cap, observed_at
  from _dash_av;
  get diagnostics n = row_count; v_stats := v_stats || jsonb_build_object('availability_store_rows', n);

  -- SKU x city rows
  insert into dash.availability (obs_date, platform, city_slug, sidnl_id, store_key,
         ds_eligible_stores, ds_listed_stores, ds_listing_pct,
         osa_eligible_obs, osa_available_obs, osa_pct, osa_in_ls_eligible_obs, osa_in_ls_available_obs, osa_in_ls_pct,
         in_stock_stores, out_of_stock_stores, low_stock_stores, inventory_fe, inventory_fe_capped_stores, last_observed_at,
         is_critical, priority)
  select obs_date, platform, city_slug, sidnl_id, null,
         sum(dse), sum(dsl), case when sum(dse) > 0 then round(100.0 * sum(dsl) / sum(dse), 2) end,
         sum(oe), sum(oa), case when sum(oe) > 0 then round(100.0 * sum(oa) / sum(oe), 2) end,
         sum(ole), sum(ola), case when sum(ole) > 0 then round(100.0 * sum(ola) / sum(ole), 2) end,
         sum(ins), sum(oos), sum(low), sum(inv), sum(cap), max(observed_at),
         case when sum(oe) > 0 then 100.0 * sum(oa) / sum(oe) < v_crit end,
         case when sum(oe) = 0 then null
              when 100.0 * sum(oa) / sum(oe) < v_hi then 'High'
              when 100.0 * sum(oa) / sum(oe) < v_med then 'Medium' else 'Low' end
  from _dash_av
  group by obs_date, platform, city_slug, sidnl_id;
  get diagnostics n = row_count; v_stats := v_stats || jsonb_build_object('availability_city_rows', n);

  -- PSL proxy, DRR and DOI on city rows (DRR/DOI stay NULL until dash.overview has units_sold)
  update dash.availability a set
         potential_sales_loss = q.psl,
         drr = q.drr,
         doi_fe = case when q.drr > 0 and a.inventory_fe is not null then round(a.inventory_fe / q.drr, 1) end
  from (
    select c.obs_date, c.platform, c.city_slug, c.sidnl_id,
           round(c.out_of_stock_stores * coalesce(p.selling_price, nat.sp), 2) as psl,
           s.drr
    from dash.availability c
    left join dash.pricing p on p.obs_date = c.obs_date and p.platform = c.platform
                            and p.city_slug = c.city_slug and p.sidnl_id = c.sidnl_id
    left join (select platform, sidnl_id, avg(selling_price) as sp from dash.pricing group by 1, 2) nat
           on nat.platform = c.platform and nat.sidnl_id = c.sidnl_id
    left join lateral (select round(sum(o.units_sold)::numeric / 30, 2) as drr from dash.overview o
                       where o.platform = c.platform and o.city_slug = c.city_slug and o.sidnl_id = c.sidnl_id
                         and o.obs_date > c.obs_date - 30 and o.obs_date <= c.obs_date
                       having count(*) > 0) s on true
    where c.store_key is null
  ) q
  where a.store_key is null
    and a.obs_date = q.obs_date and a.platform = q.platform and a.city_slug = q.city_slug and a.sidnl_id = q.sidnl_id;

  -- ════════════════════════════ VISIBILITY ════════════════════════════
  delete from dash.visibility where obs_date >= v_vis_from;

  -- category shelves: every brand on the shelf, so SOV has a real denominator
  insert into dash.visibility (obs_date, platform, city_slug, search_type, search_term, sidnl_id,
         stores_scanned, stores_listed, listing_coverage_pct,
         impressions, organic_impressions, paid_impressions,
         top_of_search_impressions, top_of_search_organic_impressions, top_of_search_paid_impressions,
         best_search_rank, avg_search_rank, avg_organic_rank,
         share_of_voice_pct, organic_sov_pct, paid_sov_pct,
         top_of_search_sov_pct, top_of_search_organic_sov_pct, top_of_search_paid_sov_pct)
  with snap as (                       -- latest read of each shelf per store per day
    select distinct on (platform, l1_id, l2_id, store_key, obs_date) snapshot_id
    from silver.fact_shelf_position
    where store_key is not null and obs_date >= v_vis_from
    order by platform, l1_id, l2_id, store_key, obs_date, observed_at desc, snapshot_id desc
  ), r as (
    select f.obs_date, f.platform, coalesce(f.city_slug, '(unknown)') as c, f.l1_id || '>' || f.l2_id as term,
           f.store_key, x.sidnl_id, f.brand_key, f.shelf_position, f.organic_position, coalesce(f.is_ad, false) as ad
    from silver.fact_shelf_position f
    join snap s on s.snapshot_id = f.snapshot_id
    join silver.product_xref x on x.product_key = f.product_key
    join silver.dim_platform pl on pl.platform = f.platform and not pl.is_test
    where f.dq_status = 'valid' and f.store_key is not null and f.obs_date >= v_vis_from
  ), mk as (
    select obs_date, platform, c, term,
           count(distinct store_key) as stores, count(distinct brand_key) as brands,
           count(*) as imp, count(*) filter (where not ad) as org, count(*) filter (where ad) as paid,
           count(*) filter (where shelf_position <= v_top) as top,
           count(*) filter (where shelf_position <= v_top and not ad) as top_org,
           count(*) filter (where shelf_position <= v_top and ad) as top_paid
    from r group by 1, 2, 3, 4
  ), sk as (
    select obs_date, platform, c, term, sidnl_id,
           count(distinct store_key) as stores,
           count(*) as imp, count(*) filter (where not ad) as org, count(*) filter (where ad) as paid,
           count(*) filter (where shelf_position <= v_top) as top,
           count(*) filter (where shelf_position <= v_top and not ad) as top_org,
           count(*) filter (where shelf_position <= v_top and ad) as top_paid,
           min(shelf_position) as best, round(avg(shelf_position), 2) as avg_rank, round(avg(organic_position), 2) as avg_org
    from r group by 1, 2, 3, 4, 5
  )
  select s.obs_date, s.platform, s.c, 'category', s.term, s.sidnl_id,
         m.stores, s.stores, round(100.0 * s.stores / nullif(m.stores, 0), 2),
         s.imp, s.org, s.paid, s.top, s.top_org, s.top_paid,
         s.best, s.avg_rank, s.avg_org,
         case when m.brands >= 2 and m.imp > 0      then round(100.0 * s.imp / m.imp, 3) end,
         case when m.brands >= 2 and m.org > 0      then round(100.0 * s.org / m.org, 3) end,
         case when m.brands >= 2 and m.paid > 0     then round(100.0 * s.paid / m.paid, 3) end,
         case when m.brands >= 2 and m.top > 0      then round(100.0 * s.top / m.top, 3) end,
         case when m.brands >= 2 and m.top_org > 0  then round(100.0 * s.top_org / m.top_org, 3) end,
         case when m.brands >= 2 and m.top_paid > 0 then round(100.0 * s.top_paid / m.top_paid, 3) end
  from sk s join mk m using (obs_date, platform, c, term);
  get diagnostics n = row_count; v_stats := v_stats || jsonb_build_object('visibility_category', n);

  -- keyword searches: only the searched brand's cards are kept, so rank only, SOV NULL
  insert into dash.visibility (obs_date, platform, city_slug, search_type, search_term, sidnl_id,
         stores_scanned, stores_listed, listing_coverage_pct,
         impressions, organic_impressions, paid_impressions,
         top_of_search_impressions, top_of_search_organic_impressions, top_of_search_paid_impressions,
         best_search_rank, avg_search_rank, avg_organic_rank)
  with sc as (
    select distinct on (s.store_key, lower(btrim(s.scrape_query)), (s.scanned_at at time zone 'Asia/Kolkata')::date)
           s.snapshot_id, (s.scanned_at at time zone 'Asia/Kolkata')::date as obs_date, s.platform,
           coalesce(s.city_slug, '(unknown)') as c, s.store_key, lower(btrim(s.scrape_query)) as term
    from silver.fact_store_scan s
    join silver.dim_platform pl on pl.platform = s.platform and not pl.is_test
    where s.is_valid_denominator and s.store_key is not null and nullif(btrim(s.scrape_query), '') is not null
      and (s.scanned_at at time zone 'Asia/Kolkata')::date >= v_vis_from
    order by s.store_key, lower(btrim(s.scrape_query)), (s.scanned_at at time zone 'Asia/Kolkata')::date, s.scanned_at desc, s.snapshot_id desc
  ), mk as (
    select obs_date, platform, c, term, count(distinct store_key) as stores from sc group by 1, 2, 3, 4
  ), r as (
    select sc.obs_date, sc.platform, sc.c, sc.term, sc.store_key, x.sidnl_id,
           f.search_position, f.organic_position, coalesce(f.is_ad, false) as ad
    from sc
    join silver.fact_product_reading f on f.snapshot_id = sc.snapshot_id and f.source_type = 'brand_search'
         and f.dq_status = 'valid' and f.is_listed and f.search_position is not null
    join silver.product_xref x on x.product_key = f.product_key
  )
  select r.obs_date, r.platform, r.c, 'keyword', r.term, r.sidnl_id,
         m.stores, count(distinct r.store_key), round(100.0 * count(distinct r.store_key) / nullif(m.stores, 0), 2),
         count(*), count(*) filter (where not r.ad), count(*) filter (where r.ad),
         count(*) filter (where r.search_position <= v_top),
         count(*) filter (where r.search_position <= v_top and not r.ad),
         count(*) filter (where r.search_position <= v_top and r.ad),
         min(r.search_position), round(avg(r.search_position), 2), round(avg(r.organic_position), 2)
  from r join mk m using (obs_date, platform, c, term)
  group by r.obs_date, r.platform, r.c, r.term, r.sidnl_id, m.stores;
  get diagnostics n = row_count; v_stats := v_stats || jsonb_build_object('visibility_keyword', n);

  return v_stats || jsonb_build_object('visibility_from', v_vis_from, 'refreshed_at', now());
end
$f$;

comment on function dash.refresh(integer) is
  'Rebuilds dash.pricing and dash.availability fully and dash.visibility for the last N days (NULL = all). overview/ads/supply are loaded by their own feeds.';
