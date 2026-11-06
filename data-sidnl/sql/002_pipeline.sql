-- 002: vocabulary lives in the database (editable in Supabase, no deploy), plus write-amplification fixes.

create table if not exists sidnl.ref_unit (
  unit_key text primary key, base_unit text not null, factor numeric not null);

-- brand spellings -> canonical display name. 'manual' aliases match anywhere in a product name;
-- 'auto' (learned from the platforms' own brand column) only match at the START of a name.
create table if not exists sidnl.ref_brand_alias (
  alias_key text primary key, brand text not null,
  source text not null default 'manual' check (source in ('manual','auto')),
  n bigint not null default 0, active boolean not null default true);

create table if not exists sidnl.ref_variant_synonym (
  syn_key text primary key, variant text not null, active boolean not null default true);

-- 'auto' rows are only SUGGESTIONS (active = false) until a human activates them.
create table if not exists sidnl.ref_noise_word (
  word text primary key,
  source text not null default 'manual' check (source in ('manual','auto')),
  score real, active boolean not null default true);

-- leave free space in each page so price/stock updates can be HOT (no index rewrite, less bloat)
alter table sidnl.source_products set (fillfactor = 85);
alter table sidnl.offers_latest   set (fillfactor = 80);
