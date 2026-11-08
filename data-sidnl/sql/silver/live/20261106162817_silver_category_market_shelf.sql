
-- Which shelf categories to load market-wide (all brands), seeded from the categories of tracked client products
create table silver.category_scope (
  platform text not null references silver.dim_platform(platform),
  l1_id text not null,
  l2_id text not null,
  l1_name text,
  l2_name text,
  is_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (platform, l1_id, l2_id)
);
comment on table silver.category_scope is 'Category shelves loaded market-wide (every brand) by silver.refresh_category_market(). Seeded from client product categories; insert a row to track another category.';

insert into silver.category_scope (platform, l1_id, l2_id, l1_name, l2_name)
select distinct c.platform, c.l1_id, c.l2_id, c.l1_name, c.l2_name
from silver.dim_category c
join silver.dim_product p on p.category_key = c.category_key
join silver.brand_scope b on b.brand_key = p.brand_key and b.is_enabled
where c.l1_id is not null and c.l2_id is not null;

create table silver.fact_shelf_position (
  shelf_pos_key bigint generated always as identity primary key,
  source_record_id bigint not null unique,
  snapshot_id bigint not null,
  platform text not null references silver.dim_platform(platform),
  l1_id text not null,
  l2_id text not null,
  store_key int references silver.dim_store(store_key),
  city_slug text references silver.dim_city(city_slug),
  observed_at timestamptz not null,
  obs_date date generated always as (((observed_at at time zone 'Asia/Kolkata'))::date) stored,
  shelf_position int not null,
  organic_position int,
  is_ad boolean,
  ad_type text,
  brand_raw text,
  brand_key text not null,
  is_client_brand boolean not null default false,
  platform_product_id text,
  product_name text,
  pack_raw text,
  stock_status text not null check (stock_status in ('in_stock','out_of_stock','not_listed','unknown')),
  inventory_units int,
  inventory_is_capped boolean not null default false,
  selling_price numeric,
  mrp numeric,
  discount_pct numeric generated always as (case when mrp > 0 and selling_price is not null then round(((mrp - selling_price) / mrp) * 100, 2) end) stored,
  shelf_cards_seen int,
  shelf_total_items int,
  shelf_complete boolean,
  dq_status text not null check (dq_status in ('valid','suspect','invalid')),
  dq_flags text[] not null default '{}',
  loaded_at timestamptz not null default now(),
  etl_run_id bigint references silver.etl_run(run_id)
);
create index fact_shelf_position_cat_idx on silver.fact_shelf_position (platform, l2_id, obs_date);
create index fact_shelf_position_store_idx on silver.fact_shelf_position (store_key);
comment on table silver.fact_shelf_position is 'Every product card on a scoped category shelf, ALL brands (market-wide), one row per position per shelf read. shelf_cards_seen vs shelf_total_items shows how deep the scraper read; shelf_complete=false means only the top of the shelf was captured. brand_key = client brand_key when matched, else normalised brand text.';

create or replace view silver.v_shelf_position with (security_invoker = true) as
select f.*, cs.l1_name, cs.l2_name, (cs.l1_name || ' > ' || cs.l2_name) as category_path,
       ds.store_name, ct.city_name
from silver.fact_shelf_position f
join silver.category_scope cs on cs.platform = f.platform and cs.l1_id = f.l1_id and cs.l2_id = f.l2_id
left join silver.dim_store ds on ds.store_key = f.store_key
left join silver.dim_city ct on ct.city_slug = f.city_slug;

create or replace function silver.refresh_category_market() returns jsonb
language plpgsql
set search_path = silver, public, pg_temp
as $fn$
declare
  v_run bigint; v_ins int; v_upd int; v_new_stores int; v_stats jsonb := '{}'::jsonb;
begin
  insert into silver.etl_run (brand_key) values ('(category_market)') returning run_id into v_run;

  with ins as (
    insert into silver.dim_store (platform, store_external_id, source_store_id, store_name, city_slug, latitude, longitude, first_seen_at, last_seen_at)
    select s.platform, s.external_id, s.id, s.name, s.city_slug, s.lat, s.lon, s.first_seen_at, s.last_seen_at
    from public.stores s
    where s.id in (
            select distinct coalesce(sp.store_id, sn.store_id)
            from public.shelf_positions sp
            join public.shelf_snapshots sn on sn.id = sp.snapshot_id
            join silver.category_scope cs on cs.platform = sn.platform and cs.l1_id = sn.l1_id and cs.l2_id = sn.l2_id and cs.is_enabled
            where sn.status = 'ok')
      and s.platform in (select platform from silver.dim_platform)
    on conflict (source_store_id) do nothing
    returning 1)
  select count(*) into v_new_stores from ins;
  v_stats := v_stats || jsonb_build_object('dim_store_added', v_new_stores);

  with src as (
    select sp.id, sp.snapshot_id, sn.platform, sn.l1_id, sn.l2_id, coalesce(sp.store_id, sn.store_id) as src_store,
           sn.taken_at, sp."position" as pos, sp.organic_position as opos, sp.is_ad, sp.ad_type, sp.brand,
           sp.external_id, sp.name, sp.pack, sp.state, sp.inventory, sp.inventory_capped,
           sp.price::numeric as price, sp.mrp::numeric as mrp,
           sn.cards_seen, sn.total_items, sn.complete
    from public.shelf_positions sp
    join public.shelf_snapshots sn on sn.id = sp.snapshot_id
    join silver.category_scope cs on cs.platform = sn.platform and cs.l1_id = sn.l1_id and cs.l2_id = sn.l2_id and cs.is_enabled
    join silver.dim_platform dpl on dpl.platform = sn.platform and not dpl.is_test
    where sn.status = 'ok'
  ), bm as (
    select x.b as raw_brand,
           (select sb.brand_key from silver.brand_scope sb
             where sb.is_enabled and silver.brand_matches(sb.brand_key, x.b)
             order by sb.brand_key limit 1) as client_key
    from (select distinct brand as b from src where brand is not null) x
  ), ins as (
    insert into silver.fact_shelf_position (
      source_record_id, snapshot_id, platform, l1_id, l2_id, store_key, city_slug, observed_at, shelf_position, organic_position,
      is_ad, ad_type, brand_raw, brand_key, is_client_brand, platform_product_id, product_name, pack_raw,
      stock_status, inventory_units, inventory_is_capped, selling_price, mrp,
      shelf_cards_seen, shelf_total_items, shelf_complete, dq_status, dq_flags, etl_run_id)
    select s.id, s.snapshot_id, s.platform, s.l1_id, s.l2_id, ds.store_key, ds.city_slug, s.taken_at, s.pos, s.opos,
           s.is_ad, s.ad_type, s.brand,
           coalesce(bm.client_key, case when s.brand is null then null else nullif(silver.norm_key(s.brand), '') end, '(unknown)'),
           bm.client_key is not null,
           s.external_id, s.name, s.pack,
           q.status, s.inventory, coalesce(s.inventory_capped, false), round(s.price, 2), round(s.mrp, 2),
           s.cards_seen, s.total_items, s.complete, silver.dq_status(q.flags), q.flags, v_run
    from src s
    left join bm on bm.raw_brand = s.brand
    left join silver.dim_store ds on ds.source_store_id = s.src_store
    cross join lateral (
      select silver.map_stock_status(s.state) as status,
             silver.reading_dq(true, ds.store_key is not null, s.taken_at, silver.map_stock_status(s.state),
                               s.inventory, round(s.price, 2), round(s.mrp, 2)) as flags) q
    on conflict (source_record_id) do update set
      snapshot_id = excluded.snapshot_id, store_key = excluded.store_key, city_slug = excluded.city_slug,
      observed_at = excluded.observed_at, shelf_position = excluded.shelf_position, organic_position = excluded.organic_position,
      is_ad = excluded.is_ad, ad_type = excluded.ad_type, brand_raw = excluded.brand_raw, brand_key = excluded.brand_key,
      is_client_brand = excluded.is_client_brand, platform_product_id = excluded.platform_product_id,
      product_name = excluded.product_name, pack_raw = excluded.pack_raw, stock_status = excluded.stock_status,
      inventory_units = excluded.inventory_units, inventory_is_capped = excluded.inventory_is_capped,
      selling_price = excluded.selling_price, mrp = excluded.mrp, shelf_cards_seen = excluded.shelf_cards_seen,
      shelf_total_items = excluded.shelf_total_items, shelf_complete = excluded.shelf_complete,
      dq_status = excluded.dq_status, dq_flags = excluded.dq_flags, loaded_at = now(), etl_run_id = excluded.etl_run_id
    returning (xmax = 0) as inserted)
  select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from ins;
  v_stats := v_stats || jsonb_build_object('fact_shelf_position', jsonb_build_object('inserted', v_ins, 'updated', v_upd));

  v_stats := v_stats || jsonb_build_object('run_id', v_run,
    'dq', (select coalesce(jsonb_object_agg(dq_status, n), '{}'::jsonb)
             from (select dq_status, count(*) n from silver.fact_shelf_position group by 1) d));
  update silver.etl_run set finished_at = now(), status = 'success', stats = v_stats where run_id = v_run;
  return v_stats;
end
$fn$;
comment on function silver.refresh_category_market() is 'Loads market-wide shelf positions for enabled silver.category_scope rows. Called by silver.refresh_all().';

-- call it from refresh_all
do $$
declare d text;
begin
  d := pg_get_functiondef('silver.refresh_all()'::regprocedure);
  if position('return v_out;' in d) = 0 then raise exception 'marker not found in silver.refresh_all()'; end if;
  execute replace(d, 'return v_out;', E'v_out := v_out || jsonb_build_object(''category_market'', silver.refresh_category_market());\n    return v_out;');
end $$;

alter table silver.category_scope enable row level security;
alter table silver.fact_shelf_position enable row level security;

-- keep the metric documentation in silver honest
update silver.ref_metric_support set
  silver_source = 'fact_shelf_position (category shelf, all brands): brand rows vs market rows',
  notes = 'Market denominator now exists for Frozen Veg Snacks: silver.fact_shelf_position holds every brand on the shelf. Limits: top 30 cards only (shelf holds 111-247 items), 11 stores, one day. Impressions = shelf positions. Never add organic + paid SOV.'
where metric in ('Overall SOV (%)','Organic SOV / Paid SOV (%)','Category Impression Share');
update silver.ref_metric_support set
  silver_source = 'fact_shelf_position.shelf_position, is_ad',
  notes = 'Top-N cut-off lives in gold.cfg_threshold (default 10, unconfirmed). Competitor shelf data now loaded; coverage limited to the top 30 cards at 11 stores on one day.'
where metric = 'Top of Search SOV (all / organic / paid)';
update silver.ref_metric_support set
  silver_source = 'fact_shelf_position (competitor selling_price, mrp, discount_pct per brand)',
  notes = 'Competitor discount and average SP now available from shelf cards (same coverage limits). Competitor sales-based share remains not_available.'
where metric = 'Competitor market share / discount / average SP';
update silver.ref_metric_support set
  notes = 'Eligible = stores with a valid latest scan. Stopped-early scans still read 61-112 cards while brand cards rank within the first 5 positions, so false negatives are unlikely; gold flags a scan shallow only below gold.cfg_threshold.min_scan_depth_cards.'
where metric = 'Dark-store listing (%)';
