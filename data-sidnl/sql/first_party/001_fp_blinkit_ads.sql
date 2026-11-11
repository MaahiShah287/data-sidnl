-- =============================================================================
-- File:    first_party/001_fp_blinkit_ads.sql
-- Purpose: First-party (seller-portal) ads data for Mr Munchies — bronze,
--          silver, dash fill. Source: Blinkit ads portal Excel exports.
-- Status:  NOT APPLIED — run by an admin (Supabase SQL editor) BEFORE the
--          loader (scripts/load_first_party.py) is used.
-- Conventions followed: bronze = raw copied values; silver = one row per
-- bronze row, values unchanged; dash.ads keyed by
-- (obs_date, platform, campaign_id, keyword, sidnl_id) — reco ads have no
-- keyword, so they collapse to campaign-level per day.
-- Rollback: first_party/001_rollback.sql
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. BRONZE — public.fp_blinkit_ads (typed copy of every Excel row)
-- ---------------------------------------------------------------------------
create table if not exists public.fp_blinkit_ads(
  id                 bigint generated always as identity primary key,
  report_type        text not null check (report_type in
                       ('keyword_daily','reco_daily','sov_period','mtd_claimables')),
  obs_date           date,
  period_start       date,
  period_end         date,
  campaign_id        text not null,
  campaign_name      text,
  subcampaign_id     text,
  ad_type            text,                    -- Product Booster / Recommendation Ads / ...
  target_type        text,                    -- Keyword / Asset / (null)
  target_value       text,                    -- keyword or asset/title
  match_type         text,
  pacing_type        text,
  most_viewed_position int,
  cpm                numeric(14,2),
  total_budget       numeric(14,2),
  impressions        bigint,
  direct_atc         bigint,
  indirect_atc       bigint,
  new_users          bigint,
  direct_sales       numeric(14,2),
  indirect_sales     numeric(14,2),
  direct_qty         bigint,
  indirect_qty       bigint,
  budget_consumed    numeric(14,2),
  direct_roas        numeric(10,2),
  total_roas         numeric(10,2),
  searches           bigint,                  -- sov_period rows
  sov_pct            numeric(7,3),            -- sov_period rows
  claimables         numeric(14,2),           -- mtd_claimables rows
  served_budget      numeric(14,2),           -- mtd_claimables rows
  raw                jsonb not null,          -- the full original row, untouched
  source_file        text not null,
  loaded_at          timestamptz not null default now()
);

-- file registry: a file is loaded at most once (idempotent reloads)
create table if not exists public.fp_load_file(
  file_sha256 text primary key,
  file_name   text not null,
  loaded_at   timestamptz not null default now(),
  row_count   int not null
);

-- row-level dedup: same (report grain, date, campaign, target) never twice
create unique index if not exists fp_blinkit_ads_uq on public.fp_blinkit_ads(
  report_type,
  coalesce(obs_date,     date '1900-01-01'),
  campaign_id,
  coalesce(subcampaign_id, ''),
  coalesce(target_value,   ''),
  coalesce(period_start, date '1900-01-01')
);

comment on table public.fp_blinkit_ads is
  'First-party Blinkit ads portal exports (Mr Munchies). Bronze: values copied as downloaded. Loaded by scripts/load_first_party.py.';

-- ---------------------------------------------------------------------------
-- 2. SILVER — silver.fact_fp_ads (one row per bronze row; values unchanged)
-- ---------------------------------------------------------------------------
create table if not exists silver.fact_fp_ads(
  fp_ads_id          bigint primary key references public.fp_blinkit_ads(id),
  report_type        text not null,
  obs_date           date,
  period_start       date,
  period_end         date,
  campaign_id        text not null,
  campaign_name      text,
  subcampaign_id     text,
  ad_type            text,
  target_type        text,
  target_value       text,
  match_type         text,
  most_viewed_position int,
  cpm                numeric(14,2),
  total_budget       numeric(14,2),
  impressions        bigint,
  direct_atc         bigint,
  indirect_atc       bigint,
  new_users          bigint,
  direct_sales       numeric(14,2),
  indirect_sales     numeric(14,2),
  direct_qty         bigint,
  indirect_qty       bigint,
  budget_consumed    numeric(14,2),
  direct_roas        numeric(10,2),
  total_roas         numeric(10,2),
  searches           bigint,
  sov_pct            numeric(7,3),
  claimables         numeric(14,2),
  served_budget      numeric(14,2),
  dq_status          text not null default 'valid' check (dq_status in ('valid','suspect','invalid')),
  loaded_at          timestamptz not null default now()
);
alter table silver.fact_fp_ads enable row level security;
comment on table silver.fact_fp_ads is
  'First-party ads facts (Blinkit portal, Mr Munchies). One row per public.fp_blinkit_ads row. Products are not in portal reports — the grain is campaign/target, not sidnl_id.';

-- ---------------------------------------------------------------------------
-- 3. SILVER loader — idempotent upsert from bronze
-- ---------------------------------------------------------------------------
create or replace function silver.load_fp_ads()
returns jsonb
language plpgsql
set search_path to 'silver', 'public', 'pg_temp'
as $$
declare
  v_rows bigint;
begin
  insert into silver.fact_fp_ads(fp_ads_id, report_type, obs_date, period_start, period_end,
    campaign_id, campaign_name, subcampaign_id, ad_type, target_type, target_value,
    match_type, most_viewed_position, cpm, total_budget, impressions,
    direct_atc, indirect_atc, new_users, direct_sales, indirect_sales,
    direct_qty, indirect_qty, budget_consumed, direct_roas, total_roas,
    searches, sov_pct, claimables, served_budget, loaded_at)
  select id, report_type, obs_date, period_start, period_end,
    campaign_id, campaign_name, subcampaign_id, ad_type, target_type, target_value,
    match_type, most_viewed_position, cpm, total_budget, impressions,
    direct_atc, indirect_atc, new_users, direct_sales, indirect_sales,
    direct_qty, indirect_qty, budget_consumed, direct_roas, total_roas,
    searches, sov_pct, claimables, served_budget, loaded_at
  from public.fp_blinkit_ads b
  where not exists (select 1 from silver.fact_fp_ads s where s.fp_ads_id = b.id)
  on conflict (fp_ads_id) do nothing;
  get diagnostics v_rows = row_count;

  -- quality: negative money or nonsensical roas marks the row suspect
  update silver.fact_fp_ads
     set dq_status = 'suspect'
   where dq_status = 'valid'
     and (direct_sales < 0 or indirect_sales < 0 or budget_consumed < 0
          or direct_roas < 0 or total_roas < 0);

  return jsonb_build_object('status','ok','new_silver_rows', v_rows,
                            'total', (select count(*) from silver.fact_fp_ads));
end $$;

-- ---------------------------------------------------------------------------
-- 4. DASH — dash.refresh_ads(): rebuild dash.ads from silver (delete+insert,
--    same atomic pattern as the other dash tables). Additive: dash.refresh
--    is NOT modified; a dedicated cron calls this.
-- ---------------------------------------------------------------------------
create or replace function dash.refresh_ads()
returns jsonb
language plpgsql
set search_path to 'dash', 'silver', 'pg_temp'
as $$
declare
  v_rows bigint;
  v_t0   timestamptz := clock_timestamp();
begin
  delete from dash.ads;

  -- keyword-level daily rows (Keyword Targeting / PRODUCT_LISTING)
  insert into dash.ads(obs_date, platform, campaign_id, keyword, sidnl_id,
    campaign_name, campaign_type, campaign_budget, ad_spend, impressions,
    direct_sales, indirect_sales, attributed_sales,
    direct_roas, total_roas, new_users_acquired,
    direct_atc, indirect_atc, atc,
    direct_qty_sold, indirect_qty_sold, total_qty_sold, most_viewed_position, cpm)
  select obs_date, 'blinkit', campaign_id, target_value, null,
    max(campaign_name), max(ad_type), max(total_budget), max(budget_consumed), max(impressions),
    max(direct_sales), max(indirect_sales), max(direct_sales) + max(indirect_sales),
    max(direct_roas), max(total_roas), max(new_users),
    max(direct_atc), max(indirect_atc), max(direct_atc) + max(indirect_atc),
    max(direct_qty), max(indirect_qty), max(direct_qty) + max(indirect_qty),
    max(most_viewed_position), max(cpm)
  from silver.fact_fp_ads
  where report_type = 'keyword_daily' and dq_status = 'valid'
  group by obs_date, campaign_id, target_value
  on conflict do nothing;

  -- recommendation ads: no keyword/sku → collapse to campaign-level per day
  -- (dash.ads PK is (obs_date, platform, campaign_id, keyword, sidnl_id))
  insert into dash.ads(obs_date, platform, campaign_id, keyword, sidnl_id,
    campaign_name, campaign_type, campaign_budget, ad_spend, impressions,
    direct_sales, indirect_sales, attributed_sales,
    direct_roas, total_roas, new_users_acquired,
    direct_atc, indirect_atc, atc,
    direct_qty_sold, indirect_qty_sold, total_qty_sold, cpm)
  select obs_date, 'blinkit', campaign_id, null, null,
    max(campaign_name), 'Recommendation Ads', max(total_budget),
    sum(budget_consumed), sum(impressions),
    sum(direct_sales), sum(indirect_sales), sum(direct_sales) + sum(indirect_sales),
    case when sum(budget_consumed) > 0 then sum(direct_sales)/sum(budget_consumed) end,
    case when sum(budget_consumed) > 0
         then (sum(direct_sales)+sum(indirect_sales))/sum(budget_consumed) end,
    sum(new_users),
    sum(direct_atc), sum(indirect_atc), sum(direct_atc) + sum(indirect_atc),
    sum(direct_qty), sum(indirect_qty), sum(direct_qty) + sum(indirect_qty),
    max(cpm)
  from silver.fact_fp_ads
  where report_type = 'reco_daily' and dq_status = 'valid'
  group by obs_date, campaign_id
  on conflict do nothing;

  -- campaign-level MTD summary (MTD Claimables sheet): obs_date = load day
  insert into dash.ads(obs_date, platform, campaign_id, keyword, sidnl_id,
    campaign_name, campaign_type, campaign_budget, impressions)
  select (select max(obs_date) from silver.fact_fp_ads where obs_date is not null),
         'blinkit', campaign_id, null, null,
    max(campaign_name), max(ad_type), max(total_budget), max(impressions)
  from silver.fact_fp_ads
  where report_type = 'mtd_claimables' and dq_status = 'valid'
  group by campaign_id
  on conflict do nothing;

  get diagnostics v_rows = row_count;
  insert into dash.refresh_table_state(table_name, last_refreshed_at, row_count,
    last_attempt_at, last_status)
  values ('ads', now(), (select count(*) from dash.ads), now(), 'success')
  on conflict (table_name) do update
    set last_refreshed_at = now(), row_count = (select count(*) from dash.ads),
        last_attempt_at = now(), last_status = 'success', last_error = null;

  return jsonb_build_object('status','success','rows', (select count(*) from dash.ads),
                            'ms', round(extract(epoch from clock_timestamp()-v_t0)*1000));
exception when others then
  insert into dash.refresh_table_state(table_name, last_attempt_at, last_status, last_error)
  values ('ads', now(), 'failed', sqlerrm)
  on conflict (table_name) do update
    set last_attempt_at = now(), last_status = 'failed', last_error = sqlerrm;
  return jsonb_build_object('status','failed','error', sqlerrm);
end $$;

-- ---------------------------------------------------------------------------
-- 5. VIEW — keyword-level Sponsored SoV (period grain; goes to visibility
--    only when SKU-level SoV becomes available)
-- ---------------------------------------------------------------------------
create or replace view dash.v_sov_keyword
with (security_invoker = true) as
select period_start, period_end, target_value as keyword,
       searches, sov_pct, loaded_at
from silver.fact_fp_ads
where report_type = 'sov_period' and dq_status = 'valid'
order by period_end desc, sov_pct desc;

-- ---------------------------------------------------------------------------
-- 6. CRON — refresh ads every 15 min (cheap: a few hundred rows) after the
--    gold refresh has had a chance to run
-- ---------------------------------------------------------------------------
-- [ADMIN] run this block when applying:
-- select cron.schedule('sidnl-ads-refresh', '*/15 * * * *', $cmd$
--   set statement_timeout = '120s';
--   select silver.load_fp_ads();
--   select dash.refresh_ads();
-- $cmd$);
