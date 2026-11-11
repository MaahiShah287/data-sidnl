-- =============================================================================
-- File:    first_party/003_workspace_scoping.sql
-- Purpose: Multi-brand (workspace) scoping for the first-party feeds, as
--          requested by the FastAPI team.
--          - dash.cfg_workspace_account: approved mapping
--              (platform, source account_id) -> workspace_id (UUID)
--          - account_id flows bronze -> silver -> dash.ads (additive columns,
--            no row is ever deleted or modified; correct-by-rebuild applies to
--            dash.ads which is regenerated from silver anyway)
--          - published workspace-scoped views (the ONLY relations FastAPI
--            should read for tenanted data):
--              dash.v_workspace_ads
--              dash.v_workspace_sov_keyword
--              dash.v_workspace_overview
-- Status:  NOT APPLIED — run by an admin (Supabase SQL editor).
-- Notes:   dash.overview stays EMPTY until the seller-portal sales export is
--          provided; the view is published so FastAPI can wire it now.
-- Rollback: first_party/003_rollback.sql
-- =============================================================================

-- 1. Approved mapping: source account -> workspace ----------------------------
create table if not exists dash.cfg_workspace_account (
    platform      text not null,
    account_id    text not null,          -- portal/advertiser account id, e.g. '791'
    workspace_id  uuid not null,          -- FastAPI workspace, e.g. Harsh
    brand_name    text,
    approved_by   text,
    approved_at   timestamptz not null default now(),
    notes         text,
    primary key (platform, account_id)
);

comment on table dash.cfg_workspace_account is
  'Approved ownership mapping: (platform, source account_id) -> workspace_id. Managed by DataEng; loaders never guess.';

-- current confirmed batch: Blinkit advertiser account 791 = Mr Munchies = Harsh
insert into dash.cfg_workspace_account(platform, account_id, workspace_id, brand_name, approved_by, notes)
values ('blinkit', '791', '5ee59236-8425-4302-868b-e61b692a6c5a', 'Mr Munchies', 'DataEng',
        'Confirmed by Backend (Harsh workspace) 2026-11-11')
on conflict (platform, account_id) do nothing;

-- 2. Additive account_id columns ---------------------------------------------
alter table public.fp_blinkit_ads  add column if not exists account_id text;
alter table silver.fact_fp_ads     add column if not exists account_id text;
alter table dash.ads               add column if not exists account_id text;
alter table dash.overview          add column if not exists account_id text;

comment on column public.fp_blinkit_ads.account_id is
  'Source portal account id (from the export filename, e.g. 791). Null for files that do not carry it.';

-- 3. silver.load_fp_ads(): carry account_id through ----------------------------
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
    searches, sov_pct, claimables, served_budget, account_id, loaded_at)
  select id, report_type, obs_date, period_start, period_end,
    campaign_id, campaign_name, subcampaign_id, ad_type, target_type, target_value,
    match_type, most_viewed_position, cpm, total_budget, impressions,
    direct_atc, indirect_atc, new_users, direct_sales, indirect_sales,
    direct_qty, indirect_qty, budget_consumed, direct_roas, total_roas,
    searches, sov_pct, claimables, served_budget, account_id, loaded_at
  from public.fp_blinkit_ads b
  where not exists (select 1 from silver.fact_fp_ads s where s.fp_ads_id = b.id)
  on conflict (fp_ads_id) do nothing;
  get diagnostics v_rows = row_count;

  update silver.fact_fp_ads
     set dq_status = 'suspect'
   where dq_status = 'valid'
     and (direct_sales < 0 or indirect_sales < 0 or budget_consumed < 0
          or direct_roas < 0 or total_roas < 0);

  -- backfill account_id for rows loaded before 003 (values unchanged otherwise)
  update silver.fact_fp_ads s
     set account_id = b.account_id
    from public.fp_blinkit_ads b
   where s.fp_ads_id = b.id and s.account_id is null and b.account_id is not null;

  return jsonb_build_object('status','success','new_silver_rows', v_rows,
                            'total', (select count(*) from silver.fact_fp_ads));
end $$;

-- 4. dash.refresh_ads(): also stamp account_id (same logic as 002 + column) ----
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

  insert into dash.ads(obs_date, platform, campaign_id, keyword, sidnl_id, account_id,
    campaign_name, campaign_type, campaign_budget, ad_spend, impressions,
    direct_sales, indirect_sales, attributed_sales,
    direct_roas, total_roas, new_users_acquired,
    direct_atc, indirect_atc, atc,
    direct_qty_sold, indirect_qty_sold, total_qty_sold, most_viewed_position, cpm)
  select obs_date, 'blinkit', campaign_id, target_value, null, max(account_id),
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

  insert into dash.ads(obs_date, platform, campaign_id, keyword, sidnl_id, account_id,
    campaign_name, campaign_type, campaign_budget, ad_spend, impressions,
    direct_sales, indirect_sales, attributed_sales,
    direct_roas, total_roas, new_users_acquired,
    direct_atc, indirect_atc, atc,
    direct_qty_sold, indirect_qty_sold, total_qty_sold, cpm)
  select obs_date, 'blinkit', campaign_id, null, null, max(account_id),
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

  insert into dash.ads(obs_date, platform, campaign_id, keyword, sidnl_id, account_id,
    campaign_name, campaign_type, campaign_budget, impressions)
  select (select max(obs_date) from silver.fact_fp_ads where obs_date is not null),
         'blinkit', campaign_id, null, null, max(account_id),
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

-- 5. Published workspace-scoped views (FastAPI reads these) --------------------
create or replace view dash.v_workspace_ads
with (security_invoker = true) as
select w.workspace_id, w.brand_name, a.*
from dash.ads a
join dash.cfg_workspace_account w
  on w.platform = a.platform and w.account_id = a.account_id;

comment on view dash.v_workspace_ads is
  'dash.ads scoped to workspaces via the approved account mapping. FastAPI reads this for tenanted ads data. ROLLUP WARNING: report_level=''campaign'' rows with ad_spend is null are MTD summaries, not daily rows - exclude them from daily aggregations.';

create or replace view dash.v_workspace_sov_keyword
with (security_invoker = true) as
select w.workspace_id, w.brand_name,
       s.period_start, s.period_end, s.keyword, s.searches, s.sov_pct, s.loaded_at
from silver.fact_fp_ads s
join dash.cfg_workspace_account w
  on w.platform = 'blinkit' and w.account_id = s.account_id
where s.report_type = 'sov_period' and s.dq_status = 'valid'
order by s.period_end desc, s.sov_pct desc;

comment on view dash.v_workspace_sov_keyword is
  'Keyword Share of Voice, ACCOUNT-SPECIFIC (the brand''s own sponsored share from its Blinkit advertiser account). Not a market benchmark. This is the canonical SoV relation for FastAPI (dash.ads_keyword_sov does not exist).';

create or replace view dash.v_workspace_overview
with (security_invoker = true) as
select w.workspace_id, w.brand_name, o.*
from dash.overview o
join dash.cfg_workspace_account w
  on w.platform = o.platform and w.account_id = o.account_id;

comment on view dash.v_workspace_overview is
  'Transactional sales (GMV, net sales, units) scoped to workspaces. EMPTY until the seller-portal sales export is ingested; published so FastAPI can wire it.';

-- 6. Sanity checks (run after applying) ---------------------------------------
-- select * from dash.cfg_workspace_account;
-- select silver.load_fp_ads();
-- select dash.refresh_ads();
-- select workspace_id, brand_name, count(*) from dash.v_workspace_ads group by 1,2;
-- select * from dash.v_workspace_sov_keyword;
-- select count(*) from dash.v_workspace_overview;   -- 0 until sales data arrives
