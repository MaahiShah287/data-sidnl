-- dash_009_brand_scorecard_fast
-- Same output columns and the same numbers as dash_008, rewritten for speed: dash_008 joined the visibility,
-- availability and pricing parts with four outer joins that the planner ran as merge joins on (obs_date, platform)
-- only (19M row pairs discarded; 7.5 s for v_brand_scorecard_latest). Now the parts are stacked (union all) and
-- aggregated once per key, and "latest" is a single window pass. Results were checked equal to dash_008 before apply.

create or replace view dash.v_brand_scorecard with (security_invoker = true) as
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
), u as (
    select obs_date, platform, city_slug, brand_key,
           brand_impressions, brand_organic_impressions, brand_paid_impressions, brand_top_impressions,
           skus_on_shelf, categories_present, best_shelf_rank,
           null::bigint as skus_tracked, null::bigint as osa_available_obs, null::bigint as osa_eligible_obs,
           null::bigint as listed_stores, null::bigint as eligible_stores, null::bigint as skus_with_stockouts,
           null::bigint as out_of_stock_store_skus, null::numeric as potential_sales_loss,
           null::bigint as skus_priced, null::numeric as sum_mrp, null::numeric as sum_selling_price,
           null::bigint as parity_breaks, null::bigint as parity_checked
      from vis
    union all
    select obs_date, platform, city_slug, brand_key,
           null, null, null, null, null, null, null,
           skus_tracked, osa_available_obs, osa_eligible_obs, listed_stores, eligible_stores, skus_with_stockouts,
           out_of_stock_store_skus, potential_sales_loss,
           null, null, null, null, null
      from av
    union all
    select obs_date, platform, city_slug, brand_key,
           null, null, null, null, null, null, null,
           null, null, null, null, null, null, null, null,
           skus_priced, sum_mrp, sum_selling_price, parity_breaks, parity_checked
      from pr
), g as (
    select obs_date, platform, city_slug, brand_key,
           max(brand_impressions) as brand_impressions, max(brand_organic_impressions) as brand_organic_impressions,
           max(brand_paid_impressions) as brand_paid_impressions, max(brand_top_impressions) as brand_top_impressions,
           max(skus_on_shelf) as skus_on_shelf, max(categories_present) as categories_present, max(best_shelf_rank) as best_shelf_rank,
           max(skus_tracked) as skus_tracked, max(osa_available_obs) as osa_available_obs, max(osa_eligible_obs) as osa_eligible_obs,
           max(listed_stores) as listed_stores, max(eligible_stores) as eligible_stores, max(skus_with_stockouts) as skus_with_stockouts,
           max(out_of_stock_store_skus) as out_of_stock_store_skus, max(potential_sales_loss) as potential_sales_loss,
           max(skus_priced) as skus_priced, max(sum_mrp) as sum_mrp, max(sum_selling_price) as sum_selling_price,
           max(parity_breaks) as parity_breaks, max(parity_checked) as parity_checked
      from u
     group by obs_date, platform, city_slug, brand_key
)
select g.obs_date, g.platform, g.city_slug, g.brand_key, b.brand_name, b.company_name, b.is_client,
       -- shelf visibility (category shelves)
       m.categories_tracked, g.categories_present, g.skus_on_shelf, m.brands_on_shelf,
       case when m.market_impressions is not null then coalesce(g.brand_impressions, 0) end as shelf_impressions,
       m.market_impressions as market_shelf_impressions,
       round(100.0 * coalesce(g.brand_impressions, 0) / nullif(m.market_impressions, 0), 3) as share_of_shelf_pct,
       case when m.market_top_impressions is not null then coalesce(g.brand_top_impressions, 0) end as top_of_shelf_impressions,
       m.market_top_impressions as market_top_of_shelf_impressions,
       round(100.0 * coalesce(g.brand_top_impressions, 0) / nullif(m.market_top_impressions, 0), 3) as top_of_shelf_share_pct,
       g.brand_organic_impressions as organic_shelf_impressions,
       g.brand_paid_impressions as paid_shelf_impressions,
       g.best_shelf_rank,
       case when m.market_impressions is not null then
            rank() over (partition by g.obs_date, g.platform, g.city_slug
                         order by coalesce(g.brand_impressions, 0) desc) end as shelf_rank_among_brands,
       -- availability (client brands)
       g.skus_tracked, g.osa_available_obs, g.osa_eligible_obs,
       round(100.0 * g.osa_available_obs / nullif(g.osa_eligible_obs, 0), 2) as osa_pct,
       g.listed_stores, g.eligible_stores,
       round(100.0 * g.listed_stores / nullif(g.eligible_stores, 0), 2) as listing_pct,
       g.skus_with_stockouts, g.out_of_stock_store_skus, g.potential_sales_loss,
       -- pricing (client brands)
       g.skus_priced, g.sum_mrp, g.sum_selling_price,
       round(100.0 * (g.sum_mrp - g.sum_selling_price) / nullif(g.sum_mrp, 0), 2) as avg_discount_pct,
       g.parity_breaks, g.parity_checked
  from g
  left join mkt m on m.obs_date = g.obs_date and m.platform = g.platform and m.city_slug = g.city_slug
  left join dash.dim_brand b on b.brand_key = g.brand_key;

create or replace view dash.v_brand_scorecard_latest with (security_invoker = true) as
select obs_date, platform, city_slug, brand_key, brand_name, company_name, is_client,
       categories_tracked, categories_present, skus_on_shelf, brands_on_shelf,
       shelf_impressions, market_shelf_impressions, share_of_shelf_pct,
       top_of_shelf_impressions, market_top_of_shelf_impressions, top_of_shelf_share_pct,
       organic_shelf_impressions, paid_shelf_impressions, best_shelf_rank, shelf_rank_among_brands,
       skus_tracked, osa_available_obs, osa_eligible_obs, osa_pct, listed_stores, eligible_stores, listing_pct,
       skus_with_stockouts, out_of_stock_store_skus, potential_sales_loss,
       skus_priced, sum_mrp, sum_selling_price, avg_discount_pct, parity_breaks, parity_checked
  from (select s.*, rank() over (partition by s.platform, s.brand_key, s.city_slug order by s.obs_date desc) as rk
          from dash.v_brand_scorecard s) z
 where rk = 1;
