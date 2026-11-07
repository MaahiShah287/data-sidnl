-- =============================================================================
-- File:    silver/020_canonical_schema.sql
-- Purpose: Canonical product map ("SIDNL ID").
--
--   One real-world product  =  ONE sidnl_id (SI001, SI002, ...), on every platform.
--   The same product on two platforms  ->  both rows in silver.product_xref point to one SI id.
--   Search SI001 once (silver.sidnl_everything('SI001')) and get every table's rows
--   for that product on every platform.
--
--   silver.dim_product (platform x platform_product_id)
--        └─ silver.product_xref (product_key -> sidnl_id, how/why/score)
--                └─ silver.canonical_product (sidnl_id, canonical attributes)
--
-- Idempotent: safe to re-run.
-- =============================================================================

create extension if not exists pg_trgm with schema extensions;

-- ---------------------------------------------------------------------------
-- sidnl_config: every number the matcher / pipeline uses. Edit rows, no deploy.
-- Weights + thresholds come from config/matching.yaml (SIDNL System Design p.4).
-- ---------------------------------------------------------------------------
create table if not exists silver.sidnl_config (
    key         text primary key,
    value_num   numeric,
    value_text  text,
    description text
);
comment on table silver.sidnl_config is 'Matcher weights/thresholds and pipeline settings. Edit rows to tune; no redeploy needed.';

insert into silver.sidnl_config (key, value_num, description) values
    ('w_name',     0.35, 'Check 1 - lexical product-name similarity weight'),
    ('w_brand',    0.25, 'Check 1 - brand similarity weight'),
    ('w_size',     0.20, 'Check 2 - quantity / pack size agreement weight'),
    ('w_variant',  0.15, 'Check 2 - variant agreement weight'),
    ('w_category', 0.05, 'Check 2 - category L1/L2/L3 alignment weight'),
    ('th_auto',    0.90, 'score >= this AND strict rules pass -> auto-map to existing SI id'),
    ('th_review',  0.75, 'score >= this (but not auto) -> new SI id + manual review suggestion'),
    ('size_tol',   0.05, 'Check 3 - max relative size difference (5%)'),
    ('brand_min_sim',   0.60, 'Check 3 - below this two brands are in conflict'),
    ('variant_min_sim', 0.40, 'Check 3 - below this two variants are opposing'),
    ('pipeline_min_interval_seconds', 600, 'run_pipeline() will not start again sooner than this after the previous run (refresh_brand re-reads full history, ~90 s today)')
on conflict (key) do nothing;

create or replace function silver.cfg(p_key text)
returns numeric language sql stable parallel safe set search_path = silver, public, pg_temp as $$
    select value_num from silver.sidnl_config where key = p_key
$$;

-- ---------------------------------------------------------------------------
-- Vocabulary (editable, replaces the YAML lists): noise words + synonyms.
-- Synonyms are applied to BOTH product names and variants, so spelling
-- differences between platforms do not break a match.
-- ---------------------------------------------------------------------------
create table if not exists silver.ref_noise_word (
    word       text primary key,
    is_active  boolean not null default true
);
comment on table silver.ref_noise_word is 'Uninformative tokens dropped from names before lexical matching.';

create table if not exists silver.ref_variant_synonym (
    syn_key    text primary key,          -- normalised (lower, single spaces), may be multi-word
    variant    text not null,             -- canonical token it is rewritten to
    is_active  boolean not null default true
);
comment on table silver.ref_variant_synonym is 'syn_key -> canonical token, applied to names and variants before comparison.';

insert into silver.ref_noise_word (word) values
    ('can'),('bottle'),('pet'),('tin'),('pack'),('of'),('pcs'),('pc'),('ml'),('ltr'),('soft'),('drink'),
    ('cold'),('beverage'),('carbonated'),('flavoured'),('flavored'),('new'),('with'),('and'),('online'),
    ('buy'),('best'),('quality'),('original'),('combo'),('set'),('gm'),('gms'),('kg'),('the'),('by')
on conflict (word) do nothing;

insert into silver.ref_variant_synonym (syn_key, variant) values
    ('diet','diet'),('light','diet'),('lite','diet'),
    ('zero','zero'),('sugar free','zero'),('sugarfree','zero'),('no sugar','zero'),('zero sugar','zero'),
    ('classic','classic'),('original','classic'),('regular','classic'),
    ('lime','lime'),('nimbu','lime'),('lemon','lime'),
    ('orange','orange'),('mango','mango'),('cherry','cherry'),('vanilla','vanilla'),
    ('black','black'),('white','white'),('silver','silver'),('blue','blue'),('red','red'),('gold','gold'),
    ('small','small'),('medium','medium'),('large','large'),('xl','xl'),('extra large','xl'),('xxl','xxl')
on conflict (syn_key) do nothing;
-- Only the vocabulary from config/matching.yaml is seeded. Add spelling variants you actually see across
-- platforms with: insert into silver.ref_variant_synonym (syn_key, variant) values ('<spelling>', '<canonical>');
-- NB: yaml entries 's', 'm', 'l' (sizes) are intentionally NOT seeded: single letters collide with pack units.

-- ---------------------------------------------------------------------------
-- SI id generator.  SI001 ... SI999, SI1000, SI1001 ... (never truncates)
-- ---------------------------------------------------------------------------
create sequence if not exists silver.sidnl_id_seq;

create or replace function silver.format_sidnl_id(p_n bigint)
returns text language sql immutable parallel safe set search_path = silver, public, pg_temp as $$
    select 'SI' || case when p_n < 1000 then lpad(p_n::text, 3, '0') else p_n::text end
$$;

create or replace function silver.next_sidnl_id()
returns text language sql volatile set search_path = silver, public, pg_temp as $$
    select silver.format_sidnl_id(nextval('silver.sidnl_id_seq'))
$$;

-- Accepts 'si1', ' SI001 ', 'SI0001' -> 'SI001'; NULL when it is not an SI id.
create or replace function silver.sidnl_normalize(p_id text)
returns text language sql immutable parallel safe set search_path = silver, public, pg_temp as $$
    select case
             when upper(btrim(coalesce(p_id, ''))) ~ '^SI0*[1-9][0-9]*$'
             then silver.format_sidnl_id(regexp_replace(upper(btrim(p_id)), '^SI0*', '')::bigint)
           end
$$;

-- ---------------------------------------------------------------------------
-- canonical_product: THE product, one row per SI id.
-- Attributes mirror the "features" the matcher compares (name tokens, variant,
-- size/unit, pack count, category). They follow the anchor member.
-- ---------------------------------------------------------------------------
create table if not exists silver.canonical_product (
    sidnl_id           text primary key check (sidnl_id ~ '^SI[0-9]{3,}$'),
    brand_key          text not null references silver.dim_brand (brand_key),
    canonical_name     text not null,                 -- display name (anchor member's name)
    name_clean         text,                          -- order-invariant lexical key
    variant            text,
    variant_key        text,
    product_type       text,
    size_value         numeric,
    size_unit          text,
    pack_count         int not null default 1,
    category_l1        text,
    category_l2        text,
    category_l3        text,
    anchor_product_key int,                           -- member whose attributes define the canonical row
    created_method     text not null default 'auto',  -- auto | manual
    is_active          boolean not null default true,
    merged_into        text references silver.canonical_product (sidnl_id),
    created_at         timestamptz not null default now(),
    check (is_active or merged_into is not null)
);
comment on table silver.canonical_product is 'One row per real-world product (SI id). Retired ids keep merged_into so old SI ids still resolve.';
create index if not exists ix_canon_brand_pack on silver.canonical_product (brand_key, pack_count) where is_active;
create index if not exists ix_canon_name_trgm on silver.canonical_product using gin (name_clean extensions.gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- product_xref: which SI id each (platform, platform product id) belongs to.
-- ---------------------------------------------------------------------------
create table if not exists silver.product_xref (
    product_key   int primary key references silver.dim_product (product_key) on delete cascade,
    sidnl_id      text not null references silver.canonical_product (sidnl_id),
    match_status  text not null check (match_status in ('MAPPED','NEW_MASTER','PENDING_REVIEW','MANUAL')),
    match_method  text not null,        -- CATALOG_LINK | ATTRIBUTE_AUTO | ATTRIBUTE_REVIEW | NEW_MASTER | REVIEW_APPROVED | REVIEW_REJECTED | MERGED | MANUAL_SPLIT
    score         numeric,
    score_detail  jsonb not null default '{}'::jsonb,   -- name/brand/size/variant/category sims + rule result
    matched_at    timestamptz not null default now(),
    reviewed_by   text,
    reviewed_at   timestamptz
);
comment on table silver.product_xref is 'dim_product -> SI id, with how it was matched. PENDING_REVIEW = provisional own SI id plus a suggestion in match_review_queue.';
create index if not exists ix_xref_sidnl on silver.product_xref (sidnl_id);

-- ---------------------------------------------------------------------------
-- match_review_queue: 0.75 <= score < 0.90 (or strict-rule conflict) suggestions.
-- ---------------------------------------------------------------------------
create table if not exists silver.match_review_queue (
    review_id           bigint generated always as identity primary key,
    product_key         int not null references silver.dim_product (product_key) on delete cascade,
    suggested_sidnl_id  text not null references silver.canonical_product (sidnl_id),
    score               numeric not null,
    rule_ok             boolean not null,
    rule_reason         text,
    score_detail        jsonb not null default '{}'::jsonb,
    status              text not null default 'pending' check (status in ('pending','approved','rejected')),
    created_at          timestamptz not null default now(),
    decided_by          text,
    decided_at          timestamptz
);
comment on table silver.match_review_queue is 'Possible same-product pairs awaiting a human. Approve = merge into the suggested SI id; reject = keep separate.';
create index if not exists ix_review_pending on silver.match_review_queue (status) where status = 'pending';
create unique index if not exists ux_review_pair on silver.match_review_queue (product_key, suggested_sidnl_id);

-- One SI id never holds two products of the same platform (they are different SKUs).
-- Enforced in code (map_product / merge_canonical) because it spans dim_product.
