-- =============================================================================
-- File:    silver/003_facts.sql
-- Purpose: Fact tables of the silver star schema.
--
--   fact_product_reading  GRAIN: one product reading at one dark store at one time,
--                         from any source (stock check | brand search | category shelf).
--                         Carries availability, FE inventory, SP/MRP/discount and
--                         shelf rank / ad flag. Feeds OSA, pricing, SOV, inventory.
--   fact_store_scan       GRAIN: one brand-search scan of one dark store.
--                         Holds the scans that found NOTHING, which is what makes
--                         dark-store listing % computable (denominator = valid scans).
--
-- Rows are never deleted for being old. "Fresh vs stale" is derived in views.
-- =============================================================================

create table if not exists silver.fact_store_scan (
    snapshot_id          bigint primary key,                         -- public.search_snapshots.id
    scrape_id            int,
    scrape_query         text,
    platform             text not null references silver.dim_platform (platform),
    brand_key            text not null references silver.dim_brand (brand_key),
    store_key            int references silver.dim_store (store_key),          -- store that actually answered
    planned_store_key    int references silver.dim_store (store_key),          -- store the scraper targeted
    city_slug            text references silver.dim_city (city_slug),
    scanned_at           timestamptz not null,
    scan_status          text not null,                              -- ok | empty | failed
    pages_read           int,
    cards_seen           int,
    brand_cards_matched  int,
    is_complete          boolean,
    stopped_early        boolean,
    is_valid_denominator boolean not null,                           -- ok scan with a resolved store
    dq_flags             text[] not null default '{}',
    loaded_at            timestamptz not null default now(),
    etl_run_id           bigint references silver.etl_run (run_id)
);
comment on table silver.fact_store_scan is 'One brand-search scan of one dark store. is_valid_denominator = status ok AND store resolved; use it as the "eligible stores" base for listing %.';
comment on column silver.fact_store_scan.stopped_early is 'Scraper stopped paging before the end of the result list: a brand card absent from a stopped-early scan may be a false negative.';
create index if not exists ix_scan_store_time on silver.fact_store_scan (store_key, scanned_at desc);
create index if not exists ix_scan_scrape on silver.fact_store_scan (scrape_id);

create table if not exists silver.fact_product_reading (
    reading_key          bigint generated always as identity primary key,
    source_type          text not null check (source_type in ('stock_check','brand_search','category_shelf')),
    source_table         text not null,
    source_record_id     bigint not null,                            -- bronze row id (lineage)
    product_key          int not null references silver.dim_product (product_key),
    store_key            int references silver.dim_store (store_key),          -- store whose stock/price is shown
    planned_store_key    int references silver.dim_store (store_key),          -- targeted store (search / shelf only)
    city_slug            text references silver.dim_city (city_slug),
    job_ref              text,                                       -- e.g. stock_check:12 | brand_scrape:5
    run_id               int,                                        -- check_runs.id
    scrape_id            int,                                        -- brand_scrapes.id
    snapshot_id          bigint,                                     -- search/shelf snapshot id
    listing_id           int,                                        -- platform_listings.id (stock checks)

    observed_at          timestamptz not null,
    obs_date             date generated always as ((observed_at at time zone 'Asia/Kolkata')::date) stored,

    stock_state_raw      text,
    stock_status         text not null check (stock_status in ('in_stock','out_of_stock','not_listed','unknown')),
    is_listed            boolean not null,                           -- false only for not_listed
    is_available         boolean,                                    -- true in_stock / false out_of_stock / null otherwise
    inventory_units      int,                                        -- FE inventory (store-level)
    inventory_is_capped  boolean not null default false,

    selling_price        numeric(12,2),                              -- SP
    mrp                  numeric(12,2),
    discount_amount      numeric(12,2) generated always as
                             (case when mrp > 0 and selling_price is not null then mrp - selling_price end) stored,
    discount_pct         numeric(7,2) generated always as
                             (case when mrp > 0 and selling_price is not null
                                   then round((mrp - selling_price) / mrp * 100, 2) end) stored,

    search_position      int,                                      -- rank incl. ads (search / shelf only)
    organic_position     int,
    is_ad                boolean,
    ad_type              text,

    osa_eligible         boolean not null,                           -- counts in OSA: product-page stock check, valid, available known
    dq_status            text not null check (dq_status in ('valid','suspect','invalid')),
    dq_flags             text[] not null default '{}',

    loaded_at            timestamptz not null default now(),
    etl_run_id           bigint references silver.etl_run (run_id),
    unique (source_type, source_record_id)
);
comment on table silver.fact_product_reading is
  'One product reading at one dark store at one time. Source-agnostic. Metrics must filter dq_status=''valid''; OSA additionally osa_eligible.';
comment on column silver.fact_product_reading.is_available is 'Availability as seen: in_stock=true, out_of_stock=false, not_listed/unknown=null. Brand-search cards only ever show listed items, so OSA uses stock checks only (osa_eligible).';
comment on column silver.fact_product_reading.store_key is 'The store whose inventory/price is displayed (the serving store for search cards).';
comment on column silver.fact_product_reading.inventory_units is 'Front-end (dark-store) inventory units as displayed by the platform. Back-end inventory is not available from scraping.';

create index if not exists ix_reading_prod_store_time on silver.fact_product_reading (product_key, store_key, observed_at desc);
create index if not exists ix_reading_date_prod on silver.fact_product_reading (obs_date, product_key);
create index if not exists ix_reading_store on silver.fact_product_reading (store_key);
create index if not exists ix_reading_snapshot on silver.fact_product_reading (snapshot_id) where snapshot_id is not null;
create index if not exists ix_reading_source_time on silver.fact_product_reading (source_type, observed_at desc);
