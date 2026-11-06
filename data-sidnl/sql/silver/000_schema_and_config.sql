-- =============================================================================
-- File:    silver/000_schema_and_config.sql
-- Purpose: Silver schema + the three small config / audit tables that drive it.
--
-- LAYERS
--   bronze  = raw scraper tables in `public` (observations, search_cards, ...)  [untouched]
--   silver  = cleaned, typed, de-duplicated, brand-scoped star schema           [this folder]
--   gold    = metric views for the PDF formulas (sql/gold/*)                    [reads silver]
--
-- Idempotent: safe to re-run.
-- =============================================================================

create schema if not exists silver;
comment on schema silver is
  'Cleaned, typed, brand-scoped star schema built from the raw scraper tables in public. '
  'Facts are append/upsert only; "fresh vs stale" is derived at query time (see v_reading, v_data_freshness).';

-- ---------------------------------------------------------------------------
-- brand_scope: WHICH brands silver tracks. Add a row + run silver.refresh_brand()
-- to onboard another brand. Matching is on a normalised key (case, punctuation
-- and spaces ignored), never on substring, so "Crunch & Munch" != "Mr. Munchies".
-- ---------------------------------------------------------------------------
create table if not exists silver.brand_scope (
    brand_key          text primary key,                       -- normalised, e.g. 'mr munchies'
    brand_name         text not null,                          -- display name
    company_name       text,
    raw_brand_aliases  text[] not null default '{}',           -- other raw spellings seen in bronze
    is_enabled         boolean not null default true,
    created_at         timestamptz not null default now()
);
comment on table silver.brand_scope is 'Brands tracked by silver. One row per brand; drives silver.refresh_brand().';

-- ---------------------------------------------------------------------------
-- freshness_policy: how old a reading may be before it is called STALE.
-- Rows are never deleted for being stale - history is needed for OSA trends -
-- the label is derived in views from this table.
-- ---------------------------------------------------------------------------
create table if not exists silver.freshness_policy (
    source_type         text primary key
                        check (source_type in ('stock_check','brand_search','category_shelf')),
    fresh_within_hours  int  not null check (fresh_within_hours > 0),
    description         text
);
comment on table silver.freshness_policy is 'Age threshold (hours) after which a reading is labelled stale, per source type.';

insert into silver.freshness_policy (source_type, fresh_within_hours, description) values
    ('stock_check',    48, 'Product-page stock check per dark store (public.observations)'),
    ('brand_search',   24, 'Brand search scrape per dark store (public.search_cards)'),
    ('category_shelf', 72, 'Category shelf read per dark store (public.shelf_positions)')
on conflict (source_type) do nothing;

-- ---------------------------------------------------------------------------
-- etl_run: audit log of every refresh.
-- ---------------------------------------------------------------------------
create table if not exists silver.etl_run (
    run_id       bigint generated always as identity primary key,
    brand_key    text not null,
    started_at   timestamptz not null default now(),
    finished_at  timestamptz,
    status       text not null default 'running' check (status in ('running','success','failed')),
    stats        jsonb not null default '{}'::jsonb,
    error        text
);
comment on table silver.etl_run is 'One row per silver.refresh_brand() call, with row counts in stats.';

-- Seed: the brand this project is about.
insert into silver.brand_scope (brand_key, brand_name, company_name, raw_brand_aliases)
values ('mr munchies', 'Mr. Munchies', 'Mr. Munchies', array['Mr.Munchies','Mr Munchies','MrMunchies'])
on conflict (brand_key) do nothing;
