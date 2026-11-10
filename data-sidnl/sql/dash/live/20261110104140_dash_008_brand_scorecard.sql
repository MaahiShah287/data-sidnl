-- dash_008_brand_scorecard
-- One row per obs_date x platform x city x brand that answers "how is my brand doing in this market" using ONLY numbers
-- already in dash.visibility / dash.availability / dash.pricing (themselves rebuilt from silver, which matches bronze
-- row for row). Nothing is estimated or filled in:
--   * every % column comes with its numerator and denominator, so any roll-up is SUM(num) / SUM(den)
--   * city_slug = 'ALL' rows are the same sums over all cities of that platform and date (not an average of cities)
--   * a metric that was not measured for a brand is NULL, never 0. The one exception: when a day's category shelves
--     were tracked and the brand never appeared on them, its shelf impressions are 0 (that is what the data says).
-- Coverage today: category shelves are scraped for Blinkit (all brands); availability and pricing exist for client
-- brands only (brand searches / stock checks). Read-only view; adds no table and no job.

create view dash.v_brand_scorecard with (security_invoker = true) as
with vis as (
    select v.obs_date, v.platform, coalesce(v.city_slug, 'ALL') as city_slug, s.brand_key,
           sum(v.impressions) as brand_impressions,
           sum(v.organic_impressions) as brand_organic_impressions,
           sum(v.paid_impressions) as brand_paid_impressions,
           sum(v.top_of_search_impressions) as brand_top_impressions,
           count(distinct v.sidnl_id) as skus_on_shelf,
           count(distinct v.search_term) as categories_present,
           min(v.best_search_rank) as best_shelf_rank
      from dash.visibility v
      join dash.dim_sidnl s on s.sidnl_id = v.sidnl_id
     where v.search_type = 'category'
     group by grouping sets ((v.obs_date, v.platform, v.city_slug, s.brand_key), (v.obs_date, v.platform, s.brand_key))
), mkt as (
    select v.obs_date, v.platform, coalesce(v.city_slug, 'ALL') as city_slug,
           sum(v.impressions) as market_impressions,
           sum(v.top_of_search_impressions) as market_top_impressions,
           count(distinct v.search_term) as categories_tracked,
           count(distinct s.brand_key) as brands_on_shelf
      from dash.visibility v
      join dash.dim_sidnl s on s.sidnl_id = v.sidnl_id
     where v.search_type = 'category'
     group by grouping sets ((v.obs_date, v.platform, v.city_slug), (v.obs_date, v.platform))
), av as (
    select a.obs_date, a.platform, coalesce(a.city_slug, 'ALL') as city_slug, s.brand_key,
           count(distinct a.sidnl_id) as skus_tracked,
           sum(a.osa_available_obs) as osa_available_obs,
           sum(a.osa_eligible_obs) as osa_eligible_obs,
           sum(a.ds_listed_stores) as listed_stores,
           sum(a.ds_eligible_stores) as eligible_stores,
           count(distinct a.sidnl_id) filter (where a.out_of_stock_stores > 0) as skus_with_stockouts,
           sum(a.out_of_stock_stores) as out_of_stock_store_skus,
           sum(a.potential_sales_loss) as potential_sales_loss
      from dash.availability a
      join dash.dim_sidnl s on s.sidnl_id = a.sidnl_id
     where a.store_key is null
     group by grouping sets ((a.obs_date, a.platform, a.city_slug, s.brand_key), (a.obs_date, a.platform, s.brand_key))
), pr as (
    select p.obs_date, p.platform, coalesce(p.city_slug, 'ALL') as city_slug, s.brand_key,
           count(distinct p.sidnl_id) as skus_priced,
           sum(p.mrp) as sum_mrp,
           sum(p.selling_price) as sum_selling_price,
           count(*) filter (where p.is_parity_break) as parity_breaks,
           count(*) filter (where p.is_parity_break is not null) as parity_checked
      from dash.pricing p
      join dash.dim_sidnl s on s.sidnl_id = p.sidnl_id
     group by grouping sets ((p.obs_date, p.platform, p.city_slug, s.brand_key), (p.obs_date, p.platform, s.brand_key))
), k as (
    select obs_date, platform, city_slug, brand_key from vis
    union select obs_date, platform, city_slug, brand_key from av
    union select obs_date, platform, city_slug, brand_key from pr
)
select k.obs_date, k.platform, k.city_slug, k.brand_key, b.brand_name, b.company_name, b.is_client,
       -- shelf visibility (category shelves)
       m.categories_tracked, vis.categories_present, vis.skus_on_shelf, m.brands_on_shelf,
       case when m.market_impressions is not null then coalesce(vis.brand_impressions, 0) end as shelf_impressions,
       m.market_impressions as market_shelf_impressions,
       round(100.0 * coalesce(vis.brand_impressions, 0) / nullif(m.market_impressions, 0), 3) as share_of_shelf_pct,
       case when m.market_top_impressions is not null then coalesce(vis.brand_top_impressions, 0) end as top_of_shelf_impressions,
       m.market_top_impressions as market_top_of_shelf_impressions,
       round(100.0 * coalesce(vis.brand_top_impressions, 0) / nullif(m.market_top_impressions, 0), 3) as top_of_shelf_share_pct,
       vis.brand_organic_impressions as organic_shelf_impressions,
       vis.brand_paid_impressions as paid_shelf_impressions,
       vis.best_shelf_rank,
       case when m.market_impressions is not null then
            rank() over (partition by k.obs_date, k.platform, k.city_slug
                         order by coalesce(vis.brand_impressions, 0) desc) end as shelf_rank_among_brands,
       -- availability (client brands)
       av.skus_tracked, av.osa_available_obs, av.osa_eligible_obs,
       round(100.0 * av.osa_available_obs / nullif(av.osa_eligible_obs, 0), 2) as osa_pct,
       av.listed_stores, av.eligible_stores,
       round(100.0 * av.listed_stores / nullif(av.eligible_stores, 0), 2) as listing_pct,
       av.skus_with_stockouts, av.out_of_stock_store_skus, av.potential_sales_loss,
       -- pricing (client brands)
       pr.skus_priced, pr.sum_mrp, pr.sum_selling_price,
       round(100.0 * (pr.sum_mrp - pr.sum_selling_price) / nullif(pr.sum_mrp, 0), 2) as avg_discount_pct,
       pr.parity_breaks, pr.parity_checked
  from k
  left join vis using (obs_date, platform, city_slug, brand_key)
  left join mkt m using (obs_date, platform, city_slug)
  left join av  using (obs_date, platform, city_slug, brand_key)
  left join pr  using (obs_date, platform, city_slug, brand_key)
  left join dash.dim_brand b on b.brand_key = k.brand_key;

comment on view dash.v_brand_scorecard is
  'Brand scorecard per obs_date x platform x city (ALL = all cities) x brand, built only from dash.visibility/availability/pricing. Every % has its num/den; roll up as SUM(num)/SUM(den). NULL = not measured (category shelves: Blinkit; availability/pricing: client brands). shelf impressions are 0 only when that day''s shelves were tracked and the brand did not appear.';

create view dash.v_brand_scorecard_latest with (security_invoker = true) as
select s.*
  from dash.v_brand_scorecard s
  join (select platform, brand_key, city_slug, max(obs_date) as obs_date
          from dash.v_brand_scorecard group by 1, 2, 3) l using (platform, brand_key, city_slug, obs_date);

comment on view dash.v_brand_scorecard_latest is
  'dash.v_brand_scorecard: the latest obs_date that has any data for each platform x brand x city (obs_date is in the row, so a brand sees how recent its numbers are).';
