-- =============================================================================
-- File:    silver/002_dimensions.sql
-- Purpose: Dimension tables of the silver star schema.
--
--   dim_platform ─┬─< dim_store >─── dim_city
--                 ├─< dim_product >─┬─ dim_brand ── brand_scope
--                 └─< dim_category ─┘
--
-- Surrogate keys (identity) everywhere; the bronze natural key is kept as a
-- UNIQUE column for lineage and idempotent upserts.
-- =============================================================================

create table if not exists silver.dim_platform (
    platform       text primary key,
    platform_name  text not null,
    is_test        boolean not null default false
);
comment on table silver.dim_platform is 'Quick-commerce platforms. is_test = demo/seed data that must never reach metrics.';

insert into silver.dim_platform (platform, platform_name, is_test) values
    ('blinkit',   'Blinkit',          false),
    ('zepto',     'Zepto',            false),
    ('instamart', 'Swiggy Instamart', false),
    ('jiomart',   'JioMart',          false),
    ('demo',      'Demo (test data)', true)
on conflict (platform) do nothing;

create table if not exists silver.dim_city (
    city_slug   text primary key,
    city_name   text not null,
    state       text,
    center_lat  double precision,
    center_lon  double precision
);
comment on table silver.dim_city is 'Cities covered by the scrapers (from public.cities).';

create table if not exists silver.dim_brand (
    brand_key     text primary key references silver.brand_scope (brand_key),
    brand_name    text not null,
    company_name  text,
    is_tracked    boolean not null default true
);
comment on table silver.dim_brand is 'Tracked brands (from silver.brand_scope).';

create table if not exists silver.dim_store (
    store_key          int generated always as identity primary key,
    platform           text not null references silver.dim_platform (platform),
    store_external_id  text not null,                 -- the platform''s own store id
    source_store_id    int  not null unique,          -- public.stores.id (lineage)
    store_name         text,
    city_slug          text references silver.dim_city (city_slug),
    latitude           double precision,
    longitude          double precision,
    first_seen_at      timestamptz,
    last_seen_at       timestamptz,
    unique (platform, store_external_id)
);
comment on table silver.dim_store is 'Dark stores as the platform identifies them. Includes every store scanned, so it is also the listing-% denominator universe.';
create index if not exists ix_dim_store_city on silver.dim_store (city_slug);

create table if not exists silver.dim_category (
    category_key  int generated always as identity primary key,
    platform      text not null references silver.dim_platform (platform),
    l1_id         text, l1_name text,
    l2_id         text, l2_name text,
    l3_id         text, l3_name text,
    category_path text generated always as (
        l1_name || coalesce(' > ' || l2_name, '') || coalesce(' > ' || l3_name, '')) stored,
    unique nulls not distinct (platform, l1_id, l1_name, l2_id, l2_name, l3_id, l3_name)
);
comment on table silver.dim_category is 'Platform category hierarchy (L1 > L2 > L3) parsed from listing breadcrumbs / shelf categories.';

create table if not exists silver.dim_product (
    product_key          int generated always as identity primary key,
    platform             text not null references silver.dim_platform (platform),
    platform_product_id  text not null,               -- external_id on the platform
    brand_key            text not null references silver.dim_brand (brand_key),
    product_name         text not null,
    variant              text,                        -- parsed: name minus brand/type/pack
    product_type         text,                        -- platform ptype, e.g. Samosa
    pack_raw             text,                        -- as displayed, e.g. '270 g'
    size_value           numeric,                     -- parsed, base unit (g / ml / pc)
    size_unit            text,
    pack_count           int not null default 1,
    total_content        numeric generated always as (size_value * pack_count) stored,
    category_key         int references silver.dim_category (category_key),
    listing_id           int,                         -- public.platform_listings.id when tracked
    catalog_product_id   int,                         -- public.products.id when tracked
    image_url            text,
    product_url          text,
    first_seen_at        timestamptz,
    last_seen_at         timestamptz,
    unique (platform, platform_product_id)
);
comment on table silver.dim_product is 'One row per (platform, platform product id) of a tracked brand. Pack text is parsed to size/unit/count.';
create index if not exists ix_dim_product_brand on silver.dim_product (brand_key);
create index if not exists ix_dim_product_category on silver.dim_product (category_key);
