create schema if not exists sidnl;

create table if not exists sidnl.ingest_batches (
  batch_id bigserial primary key, platform text not null, kind text not null,
  source_file text, rows_in bigint default 0,
  started_at timestamptz default now(), finished_at timestamptz);

-- BRONZE: one row per (platform, product), raw kept as jsonb
create table if not exists sidnl.source_products (
  source_id bigserial primary key,
  platform text not null, platform_product_id text not null,
  name text, brand_raw text, size_raw text, category_raw text, url text,
  raw jsonb, content_hash text,
  needs_normalize boolean not null default true,
  first_seen timestamptz not null default now(), last_seen timestamptz not null default now(),
  unique (platform, platform_product_id));
create index if not exists ix_sp_needs_norm on sidnl.source_products (source_id) where needs_normalize;

-- SILVER
create table if not exists sidnl.product_features (
  source_id bigint primary key references sidnl.source_products(source_id) on delete cascade,
  brand text not null default '', size_base numeric, size_unit text,
  pack_count int not null default 1, variant text not null default '',
  category_l1 text, category_l2 text, category_l3 text,
  name_clean text not null default '');
create index if not exists ix_pf_cohort on sidnl.product_features (brand, size_base, pack_count);
create index if not exists ix_pf_cat on sidnl.product_features (category_l1, category_l2);

-- GOLD
create table if not exists sidnl.master_products (
  master_id bigserial primary key,
  sidnl_id text generated always as ('SIDNL-' || lpad(master_id::text, 6, '0')) stored,
  brand text not null default '', size_base numeric, size_unit text,
  pack_count int not null default 1, variant text not null default '',
  category_l1 text, category_l2 text, category_l3 text,
  canonical_name text, created_at timestamptz default now());
create unique index if not exists ux_master_sidnl on sidnl.master_products (sidnl_id);
create index if not exists ix_master_cohort on sidnl.master_products (brand, size_base, pack_count);
create index if not exists ix_master_brand on sidnl.master_products (brand);
create index if not exists ix_master_cat on sidnl.master_products (category_l1, category_l2);

create table if not exists sidnl.product_map (
  source_id bigint primary key references sidnl.source_products(source_id) on delete cascade,
  master_id bigint references sidnl.master_products(master_id),
  score real, status text not null check (status in ('MAPPED','PENDING_REVIEW','UNMAPPED','MANUAL')),
  match_type text default 'ATTRIBUTE',
  mapped_at timestamptz default now());
create index if not exists ix_pm_master on sidnl.product_map (master_id);
create index if not exists ix_pm_status on sidnl.product_map (status) where status = 'PENDING_REVIEW';
create index if not exists ix_pm_match_type on sidnl.product_map (match_type);

-- HISTORY: only changes are stored, monthly partitions
create table if not exists sidnl.offers (
  source_id bigint not null, observed_at timestamptz not null,
  price numeric(12,2), mrp numeric(12,2), in_stock boolean,
  primary key (source_id, observed_at)
) partition by range (observed_at);
create table if not exists sidnl.offers_default partition of sidnl.offers default;

create or replace function sidnl.ensure_offer_partition(d date) returns void
language plpgsql as $$
declare s date := date_trunc('month', d)::date;
        e date := (date_trunc('month', d) + interval '1 month')::date;
begin
  execute format('create table if not exists sidnl.%I partition of sidnl.offers for values from (%L) to (%L)',
                 'offers_' || to_char(s, 'YYYY_MM'), s, e);
end $$;

create table if not exists sidnl.offers_latest (
  source_id bigint primary key, observed_at timestamptz not null,
  price numeric(12,2), mrp numeric(12,2), in_stock boolean);

create table if not exists sidnl.category_map (
  platform text not null, category_raw text not null,
  l1 text, l2 text, l3 text, seen_count bigint default 0,
  primary key (platform, category_raw));

-- DELIVERY: every master x every platform gets one of 3 labels
create or replace view sidnl.v_catalog as
select m.sidnl_id, m.canonical_name, m.brand, m.size_base, m.size_unit, m.pack_count, m.variant,
       p.platform,
       case when x.source_id is null then 'SKU Not Listed'
            when l.in_stock then 'SKU Available'
            else 'SKU Not Available' end as availability,
       x.source_id, l.price, l.mrp, l.observed_at
from sidnl.master_products m
cross join (select distinct platform from sidnl.source_products) p
left join lateral (
  select sp.source_id from sidnl.product_map pm
  join sidnl.source_products sp on sp.source_id = pm.source_id
  where pm.master_id = m.master_id and sp.platform = p.platform
  order by sp.source_id limit 1) x on true
left join sidnl.offers_latest l on l.source_id = x.source_id;
