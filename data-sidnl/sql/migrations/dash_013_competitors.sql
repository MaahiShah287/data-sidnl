-- dash_013: competitor layer (scraped shelf data, all brands) for the quick-commerce metric handbook.
--
-- WHAT: every brand that shares a category shelf with a client brand (silver.brand_scope.scope_source = 'client')
--       is a competitor. Today: Mr. Munchies shares Blinkit "Frozen Veg Snacks" with 39 other brands (McCain, ITC
--       Master Chef, Godrej Yummiez, HyFun, Haldiram's ...); Zepto "Veg Snacks" appears once silver_075 lets the
--       pipeline register it.
-- HOW:  dash.refresh_competitors() rebuilds two tables from silver.fact_shelf_position (valid rows only) and is run by
--       cron job sidnl-competitors every 10 minutes (same pattern as dash.refresh_ads / sidnl-fp-ads). A failed
--       refresh rolls back and keeps the previous rows; the result is in dash.refresh_table_state.
--         dash.comp_sku_day    one SKU in one city on one day: median SP / MRP, discount, price per 100 g|ml, OSA,
--                              listing stores, rank, price change vs the previous observed day, SI id (cross-platform)
--         dash.comp_brand_day  one brand in one category in one city (or 'ALL' cities) on one day: share of shelf,
--                              average rank, top-10 rate, paid share, OSA, listing %, average discount, median price
--       dash.v_comp_price_gap            client brand vs every competitor brand: price per 100 g|ml, gap, index
--       dash.v_comp_cross_marketplace    same SI id on two platforms in one city: price gap
-- RULES (handbook section 1 + 14): every % keeps its numerator and denominator (roll up as SUM/SUM); price comparisons
--       use the normalised unit price; shelf share is a PROXY for share of voice / market share (no sales feed), and
--       the price gap between two brands is a category-level proxy until a verified SKU match table exists.
-- NEEDS NO NEW BRONZE DATA: Blinkit competitor rows are already in silver (2.27 M valid shelf rows).

do $pre$
begin
    if to_regclass('silver.fact_shelf_position') is null or to_regclass('silver.dim_product') is null
       or to_regclass('dash.refresh_table_state') is null then
        raise exception 'dash_013 preflight: silver/dash base tables missing';
    end if;
end
$pre$;

create table if not exists dash.comp_sku_day (
    obs_date        date    not null,
    platform        text    not null,
    city_slug       text    not null,
    l1_id           text,
    l2_id           text    not null,
    category_name   text,
    product_key     integer not null,
    sidnl_id        text,
    brand_key       text    not null,
    brand_name      text,
    is_client       boolean not null default false,
    product_name    text,
    pack_raw        text,
    size_value      numeric,
    size_unit       text,
    total_content   numeric,
    stores_listed   integer not null,
    cards           integer not null,
    ad_cards        integer not null,
    organic_cards   integer not null,
    top10_cards     integer not null,
    in_stock_obs    integer not null,
    valid_obs       integer not null,
    rank_sum        bigint,
    rank_n          integer,
    sp_median       numeric,
    mrp_median      numeric,
    sp_min          numeric,
    sp_max          numeric,
    discount_pct    numeric,
    price_per_100   numeric,
    price_unit      text,
    osa_pct         numeric,
    avg_rank        numeric,
    prior_obs_date  date,
    prior_sp        numeric,
    sp_change_pct   numeric,
    discount_change_pts numeric,
    refreshed_at    timestamptz not null default now(),
    primary key (obs_date, platform, city_slug, l2_id, product_key)
);
create index if not exists comp_sku_day_brand_idx on dash.comp_sku_day (platform, l2_id, brand_key, obs_date);
create index if not exists comp_sku_day_sidnl_idx on dash.comp_sku_day (sidnl_id, city_slug) where sidnl_id is not null;
comment on table dash.comp_sku_day is
    'Competitor layer: one SKU x city x day from category-shelf scrapes (all brands that share a shelf with a client brand). sp_median = median over the stores that listed it; osa_pct = in_stock_obs / valid_obs.';

create table if not exists dash.comp_brand_day (
    obs_date        date    not null,
    platform        text    not null,
    l1_id           text,
    l2_id           text    not null,
    category_name   text,
    city_slug       text    not null,                -- 'ALL' = all cities together (never add it to the city rows)
    brand_key       text    not null,
    brand_name      text,
    is_client       boolean not null default false,
    cards           integer not null,                -- shelf cards of the brand
    category_cards  integer not null,                -- all shelf cards in the category (denominator of share of shelf)
    skus            integer not null,                -- distinct SKUs seen (assortment)
    stores_listed   integer not null,                -- stores where the brand was on the shelf
    stores_scanned  integer not null,                -- stores where the category shelf was read (denominator of listing %)
    ad_cards        integer not null,
    organic_cards   integer not null,
    top10_cards     integer not null,                -- organic cards at organic position <= 10
    rank_sum        bigint,
    rank_n          integer,
    in_stock_obs    integer not null,
    valid_obs       integer not null,
    sp_sum          numeric,                         -- sum of selling price / MRP over cards with both > 0
    mrp_sum         numeric,
    price_n         integer,
    median_price_per_100 numeric,                    -- median of the brand's SKU unit prices (category's main unit)
    price_unit      text,
    share_of_shelf_pct  numeric,                     -- 100 * cards / category_cards      (PROXY share of voice)
    avg_rank        numeric,                         -- rank_sum / rank_n (lower = better)
    top10_rate_pct  numeric,                         -- 100 * top10_cards / organic_cards
    paid_share_pct  numeric,                         -- 100 * ad_cards / cards
    osa_pct         numeric,                         -- 100 * in_stock_obs / valid_obs
    listing_pct     numeric,                         -- 100 * stores_listed / stores_scanned
    avg_discount_pct numeric,                        -- 100 * (mrp_sum - sp_sum) / mrp_sum
    avg_sp          numeric,
    refreshed_at    timestamptz not null default now(),
    primary key (obs_date, platform, l2_id, city_slug, brand_key)
);
create index if not exists comp_brand_day_idx on dash.comp_brand_day (platform, l2_id, obs_date, city_slug);
comment on table dash.comp_brand_day is
    'Competitor layer: one brand x category x city (or ALL) x day. Percentages are stored with their numerators and denominators; roll up as SUM(num)/SUM(den). Share of shelf is a proxy for share of voice.';

alter table dash.comp_sku_day   enable row level security;
alter table dash.comp_brand_day enable row level security;

create or replace function dash.refresh_competitors()
 returns jsonb
 language plpgsql
 set search_path to 'dash', 'silver', 'pg_temp'
as $function$
declare
    v_t0 timestamptz := clock_timestamp();
    v_sku bigint; v_brand bigint;
    v_tables text[] := array['comp_sku_day', 'comp_brand_day'];
begin
    begin
        drop table if exists _comp_base;
        create temp table _comp_base on commit drop as
        select f.obs_date, f.platform, f.l1_id, f.l2_id, coalesce(f.city_slug, 'unknown') as city_slug,
               f.store_key, f.product_key, f.brand_key, f.shelf_position, f.organic_position, f.is_ad,
               f.stock_status, f.selling_price, f.mrp
          from silver.fact_shelf_position f
          join (select distinct platform, l1_id, l2_id from silver.fact_shelf_position
                 where is_client_brand and dq_status = 'valid') s
            on s.platform = f.platform and s.l1_id = f.l1_id and s.l2_id = f.l2_id
         where f.dq_status = 'valid' and f.product_key is not null and f.brand_key is not null;

        -- ---- SKU x city x day ------------------------------------------------------------------------------------
        delete from dash.comp_sku_day;
        insert into dash.comp_sku_day (
            obs_date, platform, city_slug, l1_id, l2_id, category_name, product_key, sidnl_id, brand_key, brand_name,
            is_client, product_name, pack_raw, size_value, size_unit, total_content,
            stores_listed, cards, ad_cards, organic_cards, top10_cards, in_stock_obs, valid_obs, rank_sum, rank_n,
            sp_median, mrp_median, sp_min, sp_max, discount_pct, price_per_100, price_unit, osa_pct, avg_rank,
            prior_obs_date, prior_sp, sp_change_pct, discount_change_pts)
        with agg as (
            select b.obs_date, b.platform, b.l1_id, b.l2_id, b.city_slug, b.product_key,
                   count(distinct b.store_key)::int                                       as stores_listed,
                   count(*)::int                                                          as cards,
                   count(*) filter (where b.is_ad)::int                                   as ad_cards,
                   count(*) filter (where not b.is_ad)::int                               as organic_cards,
                   count(*) filter (where not b.is_ad and b.organic_position <= 10)::int  as top10_cards,
                   count(*) filter (where b.stock_status = 'in_stock')::int               as in_stock_obs,
                   count(*) filter (where b.stock_status in ('in_stock', 'out_of_stock'))::int as valid_obs,
                   sum(b.shelf_position)::bigint                                          as rank_sum,
                   count(b.shelf_position)::int                                           as rank_n,
                   (percentile_cont(0.5) within group (order by b.selling_price))::numeric(12,2) as sp_median,
                   (percentile_cont(0.5) within group (order by b.mrp))::numeric(12,2)    as mrp_median,
                   min(b.selling_price)::numeric(12,2) as sp_min, max(b.selling_price)::numeric(12,2) as sp_max
              from _comp_base b
             group by 1, 2, 3, 4, 5, 6),
        clients as (select brand_key from silver.brand_scope where scope_source = 'client' and is_enabled),
        sku as (
            select a.*, cs.l2_name as category_name, dp.brand_key, coalesce(db.brand_name, dp.brand_key) as brand_name,
                   (dp.brand_key in (select brand_key from clients)) as is_client,
                   dp.product_name, dp.pack_raw, dp.size_value, dp.size_unit, dp.total_content, x.sidnl_id,
                   round(100 * (a.mrp_median - a.sp_median) / nullif(a.mrp_median, 0), 2) as discount_pct,
                   case when dp.size_unit in ('g', 'ml') and dp.total_content > 0
                        then round(a.sp_median / dp.total_content * 100, 2) end            as price_per_100,
                   case when dp.size_unit in ('g', 'ml') and dp.total_content > 0 then dp.size_unit end as price_unit,
                   lag(a.sp_median)  over w as prior_sp,
                   lag(a.obs_date)   over w as prior_obs_date,
                   lag(round(100 * (a.mrp_median - a.sp_median) / nullif(a.mrp_median, 0), 2)) over w as prior_discount
              from agg a
              join silver.dim_product dp on dp.product_key = a.product_key
              left join silver.dim_brand db on db.brand_key = dp.brand_key
              left join silver.product_xref x on x.product_key = a.product_key
              left join silver.category_scope cs on cs.platform = a.platform and cs.l1_id = a.l1_id and cs.l2_id = a.l2_id
            window w as (partition by a.platform, a.city_slug, a.l2_id, a.product_key order by a.obs_date))
        select obs_date, platform, city_slug, l1_id, l2_id, category_name, product_key, sidnl_id, brand_key, brand_name,
               is_client, product_name, pack_raw, size_value, size_unit, total_content,
               stores_listed, cards, ad_cards, organic_cards, top10_cards, in_stock_obs, valid_obs, rank_sum, rank_n,
               sp_median, mrp_median, sp_min, sp_max, discount_pct, price_per_100, price_unit,
               round(100.0 * in_stock_obs / nullif(valid_obs, 0), 1),
               round(rank_sum::numeric / nullif(rank_n, 0), 2),
               prior_obs_date, prior_sp,
               round(100 * (sp_median - prior_sp) / nullif(prior_sp, 0), 2),
               round(discount_pct - prior_discount, 2)
          from sku;
        get diagnostics v_sku = row_count;

        -- ---- brand x category x city (and ALL) x day -------------------------------------------------------------
        delete from dash.comp_brand_day;
        insert into dash.comp_brand_day (
            obs_date, platform, l1_id, l2_id, category_name, city_slug, brand_key, brand_name, is_client,
            cards, category_cards, skus, stores_listed, stores_scanned, ad_cards, organic_cards, top10_cards,
            rank_sum, rank_n, in_stock_obs, valid_obs, sp_sum, mrp_sum, price_n, median_price_per_100, price_unit,
            share_of_shelf_pct, avg_rank, top10_rate_pct, paid_share_pct, osa_pct, listing_pct,
            avg_discount_pct, avg_sp)
        with tot as (
            select obs_date, platform, l2_id, coalesce(city_slug, 'ALL') as city_slug,
                   count(*)::int as category_cards, count(distinct store_key)::int as stores_scanned
              from _comp_base
             group by grouping sets ((obs_date, platform, l2_id, city_slug), (obs_date, platform, l2_id))),
        cu as (   -- the category's main unit price basis (g or ml); brands are only compared on it
            select platform, l2_id, mode() within group (order by price_unit) as unit
              from dash.comp_sku_day where price_unit is not null group by 1, 2),
        p as (
            select s.obs_date, s.platform, s.l2_id, coalesce(s.city_slug, 'ALL') as city_slug, s.brand_key,
                   percentile_cont(0.5) within group (order by s.price_per_100) as p100
              from dash.comp_sku_day s
              join cu on cu.platform = s.platform and cu.l2_id = s.l2_id and cu.unit = s.price_unit
             where s.price_per_100 is not null
             group by grouping sets ((s.obs_date, s.platform, s.l2_id, s.city_slug, s.brand_key),
                                     (s.obs_date, s.platform, s.l2_id, s.brand_key))),
        clients as (select brand_key from silver.brand_scope where scope_source = 'client' and is_enabled),
        b as (
            select obs_date, platform, max(l1_id) as l1_id, l2_id, coalesce(city_slug, 'ALL') as city_slug, brand_key,
                   count(*)::int as cards, count(distinct product_key)::int as skus,
                   count(distinct store_key)::int as stores_listed,
                   count(*) filter (where is_ad)::int as ad_cards,
                   count(*) filter (where not is_ad)::int as organic_cards,
                   count(*) filter (where not is_ad and organic_position <= 10)::int as top10_cards,
                   sum(shelf_position)::bigint as rank_sum, count(shelf_position)::int as rank_n,
                   count(*) filter (where stock_status = 'in_stock')::int as in_stock_obs,
                   count(*) filter (where stock_status in ('in_stock', 'out_of_stock'))::int as valid_obs,
                   sum(selling_price) filter (where selling_price > 0 and mrp > 0) as sp_sum,
                   sum(mrp)           filter (where selling_price > 0 and mrp > 0) as mrp_sum,
                   count(*)           filter (where selling_price > 0 and mrp > 0)::int as price_n
              from _comp_base
             group by grouping sets ((obs_date, platform, l2_id, city_slug, brand_key),
                                     (obs_date, platform, l2_id, brand_key)))
        select b.obs_date, b.platform, b.l1_id, b.l2_id, cs.l2_name, b.city_slug, b.brand_key,
               coalesce(db.brand_name, b.brand_key), (b.brand_key in (select brand_key from clients)),
               b.cards, t.category_cards, b.skus, b.stores_listed, t.stores_scanned, b.ad_cards, b.organic_cards,
               b.top10_cards, b.rank_sum, b.rank_n, b.in_stock_obs, b.valid_obs, b.sp_sum, b.mrp_sum, b.price_n,
               round(p.p100::numeric, 2), cu.unit,
               round(100.0 * b.cards / nullif(t.category_cards, 0), 2),
               round(b.rank_sum::numeric / nullif(b.rank_n, 0), 2),
               round(100.0 * b.top10_cards / nullif(b.organic_cards, 0), 2),
               round(100.0 * b.ad_cards / nullif(b.cards, 0), 2),
               round(100.0 * b.in_stock_obs / nullif(b.valid_obs, 0), 2),
               round(100.0 * b.stores_listed / nullif(t.stores_scanned, 0), 2),
               round(100 * (b.mrp_sum - b.sp_sum) / nullif(b.mrp_sum, 0), 2),
               round(b.sp_sum / nullif(b.price_n, 0), 2)
          from b
          join tot t on t.obs_date = b.obs_date and t.platform = b.platform and t.l2_id = b.l2_id and t.city_slug = b.city_slug
          left join p  on p.obs_date = b.obs_date and p.platform = b.platform and p.l2_id = b.l2_id
                      and p.city_slug = b.city_slug and p.brand_key = b.brand_key
          left join cu on cu.platform = b.platform and cu.l2_id = b.l2_id
          left join silver.dim_brand db on db.brand_key = b.brand_key
          left join silver.category_scope cs on cs.platform = b.platform and cs.l2_id = b.l2_id;
        get diagnostics v_brand = row_count;
    exception when others then
        -- the block is rolled back: both tables keep their previous rows
        insert into dash.refresh_table_state (table_name, last_attempt_at, last_status, last_error)
        select t, now(), 'failed', left(sqlerrm, 1000) from unnest(v_tables) t
        on conflict (table_name) do update
           set last_attempt_at = now(), last_status = 'failed', last_error = excluded.last_error;
        return jsonb_build_object('status', 'failed', 'error', sqlerrm, 'sqlstate', sqlstate);
    end;
    insert into dash.refresh_table_state (table_name, last_refreshed_at, row_count, last_attempt_at, last_status,
                                          last_error, gold_attempts, next_retry_at)
    select t, now(), case t when 'comp_sku_day' then v_sku else v_brand end, now(), 'success', null, 0, null
      from unnest(v_tables) t
    on conflict (table_name) do update
       set last_refreshed_at = now(), row_count = excluded.row_count, last_attempt_at = now(),
           last_status = 'success', last_error = null, gold_attempts = 0, next_retry_at = null;
    return jsonb_build_object('status', 'success', 'rows', jsonb_build_object('comp_sku_day', v_sku, 'comp_brand_day', v_brand),
                              'ms', round(extract(epoch from clock_timestamp() - v_t0) * 1000));
end $function$;

-- client brand vs every competitor brand: normalised unit price (g or ml) of the SKU medians, per city, category, day.
-- A category-level proxy: handbook rows 107/110/111/114/115/117 want verified SKU-to-SKU matches (no match table yet).
create or replace view dash.v_comp_price_gap as
with brand_price as (
    select obs_date, platform, city_slug, l2_id, category_name, brand_key, brand_name, is_client, price_unit,
           percentile_cont(0.5) within group (order by price_per_100) as p100,
           count(*)::int as sku_obs
      from dash.comp_sku_day
     where price_per_100 is not null
     group by 1, 2, 3, 4, 5, 6, 7, 8, 9)
select f.obs_date, f.platform, f.city_slug, f.l2_id, f.category_name, f.price_unit,
       f.brand_key  as focal_brand_key,  f.brand_name  as focal_brand_name,
       c.brand_key  as competitor_brand_key, c.brand_name as competitor_brand_name, c.is_client as competitor_is_client,
       round(f.p100::numeric, 2) as focal_price_per_100,
       round(c.p100::numeric, 2) as competitor_price_per_100,
       round((f.p100 - c.p100)::numeric, 2) as price_gap,
       round((100 * (f.p100 - c.p100) / nullif(c.p100, 0))::numeric, 2) as price_gap_pct,
       round((100 * f.p100 / nullif(c.p100, 0))::numeric, 2) as price_index,
       f.sku_obs as focal_sku_obs, c.sku_obs as competitor_sku_obs
  from brand_price f
  join brand_price c
    on c.obs_date = f.obs_date and c.platform = f.platform and c.city_slug = f.city_slug
   and c.l2_id = f.l2_id and c.price_unit = f.price_unit and c.brand_key <> f.brand_key
 where f.is_client;
comment on view dash.v_comp_price_gap is
    'Client brand vs competitor brand, normalised unit price. price_index = 100 * focal / competitor (>100 = focal dearer). Category-level proxy until a verified SKU match table exists.';

-- the same SI id (exact brand + name + size match) on two or more platforms, latest day per platform, per city.
create or replace view dash.v_comp_cross_marketplace as
with latest as (
    select distinct on (platform, city_slug, sidnl_id)
           platform, city_slug, sidnl_id, brand_key, brand_name, product_name, pack_raw, obs_date,
           sp_median, mrp_median, price_per_100, price_unit
      from dash.comp_sku_day
     where sidnl_id is not null and sp_median is not null
     order by platform, city_slug, sidnl_id, obs_date desc),
multi as (select city_slug, sidnl_id from latest group by 1, 2 having count(distinct platform) >= 2)
select l.sidnl_id, l.city_slug, max(l.brand_name) as brand_name, max(l.product_name) as product_name,
       max(l.pack_raw) as pack_raw,
       min(l.sp_median) as min_sp, max(l.sp_median) as max_sp,
       max(l.sp_median) - min(l.sp_median) as price_gap,
       round(100 * (max(l.sp_median) - min(l.sp_median)) / nullif(min(l.sp_median), 0), 2) as price_gap_pct,
       (array_agg(l.platform order by l.sp_median asc,  l.platform))[1] as cheapest_platform,
       (array_agg(l.platform order by l.sp_median desc, l.platform))[1] as dearest_platform,
       jsonb_object_agg(l.platform, l.sp_median) as sp_by_platform,
       jsonb_object_agg(l.platform, l.obs_date)  as obs_date_by_platform
  from latest l join multi m using (city_slug, sidnl_id)
 group by l.sidnl_id, l.city_slug;
comment on view dash.v_comp_cross_marketplace is
    'Handbook 113: same SI id on two platforms in one city. Gap % = (max SP - min SP) / min SP. Dates per platform are in obs_date_by_platform (scrape days can differ).';

-- run it every 10 minutes like the ads feed; an immediate first fill follows below.
do $cron$
begin
    if exists (select 1 from cron.job where jobname = 'sidnl-competitors') then
        perform cron.unschedule('sidnl-competitors');
    end if;
    perform cron.schedule('sidnl-competitors', '*/10 * * * *',
        $$set statement_timeout = '300s'; select dash.refresh_competitors()$$);
end
$cron$;

select dash.refresh_competitors();
