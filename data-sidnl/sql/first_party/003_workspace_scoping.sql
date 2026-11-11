-- =============================================================================
-- File:    first_party/003_workspace_scoping.sql   (v2 — merge-safe)
-- Purpose: Multi-brand (workspace) scoping for first-party feeds, requested by
--          the FastAPI team, WITHOUT touching Hardi's dash.refresh_ads() or
--          his published objects (dash.ads_keyword_sov, dash.ads_campaign_period).
--
-- Design:  ownership is resolved by CONFIG MAPPING, not by new columns:
--            dash.cfg_workspace_map (platform, scope_kind, scope_value)
--              -> workspace_id
--          scope_kind: 'account'  (portal advertiser id, e.g. '791')
--                      'campaign' (platform campaign id, e.g. '284970')
--                      'sku'      (sidnl_id — for the future sales feed)
--          Every dash.ads row carries campaign_id; every SoV row is campaign
--          'sov'; future sales rows will map by sidnl_id. Nothing is altered
--          in bronze/silver, no function is replaced, purely additive.
--
-- Published views (FastAPI reads ONLY these for tenanted data):
--            dash.v_workspace_ads
--            dash.v_workspace_sov_keyword
--            dash.v_workspace_overview
-- Rollback: first_party/003_rollback.sql
-- =============================================================================

-- 1. Approved ownership mapping ------------------------------------------------
create table if not exists dash.cfg_workspace_map (
    platform     text not null,
    scope_kind   text not null check (scope_kind in ('account','campaign','sku')),
    scope_value  text not null,
    workspace_id uuid not null,
    brand_name   text,
    approved_by  text,
    approved_at  timestamptz not null default now(),
    notes        text,
    primary key (platform, scope_kind, scope_value)
);

comment on table dash.cfg_workspace_map is
  'Approved ownership mapping (platform, scope_kind, scope_value) -> workspace_id. Managed by DataEng; loaders never guess. An unmapped row simply does not appear in workspace views.';

-- confirmed batch: Blinkit advertiser account 791 = Mr Munchies = Harsh
insert into dash.cfg_workspace_map(platform, scope_kind, scope_value, workspace_id, brand_name, approved_by, notes)
values
  ('blinkit', 'account',  '791',    '5ee59236-8425-4302-868b-e61b692a6c5a', 'Mr Munchies', 'DataEng',
   'Blinkit advertiser account; confirmed by Backend (Harsh workspace) 2026-11-11'),
  ('blinkit', 'campaign', '284970', '5ee59236-8425-4302-868b-e61b692a6c5a', 'Mr Munchies', 'DataEng',
   'Chaap Aug 2025'),
  ('blinkit', 'campaign', '330981', '5ee59236-8425-4302-868b-e61b692a6c5a', 'Mr Munchies', 'DataEng',
   'Recommendation'),
  ('blinkit', 'campaign', 'sov',    '5ee59236-8425-4302-868b-e61b692a6c5a', 'Mr Munchies', 'DataEng',
   'Sponsored SoV report rows (campaign_id placeholder ''sov'')')
on conflict (platform, scope_kind, scope_value) do nothing;

-- 2. Workspace-scoped ADS -------------------------------------------------------
-- Reads whatever dash.ads currently contains (ours or Hardi's rebuild) — no
-- coupling to how refresh_ads() builds it. Unmapped campaigns are excluded.
create or replace view dash.v_workspace_ads
with (security_invoker = true) as
select w.workspace_id, w.brand_name, a.*
from dash.ads a
join dash.cfg_workspace_map w
  on w.platform = a.platform
 and w.scope_kind = 'campaign'
 and w.scope_value = a.campaign_id;

comment on view dash.v_workspace_ads is
  'dash.ads scoped to workspaces via dash.cfg_workspace_map (campaign_id mapping). FastAPI reads this for tenanted ads data. ROLLUP WARNING: report_level=''campaign'' rows with ad_spend is null are MTD summaries — exclude from daily aggregations.';

-- 3. Workspace-scoped keyword SoV -----------------------------------------------
-- Source of truth is silver (append-only), so this view is independent of how
-- any dash table is rebuilt. SoV figures are ACCOUNT-SPECIFIC (the brand''s own
-- sponsored share), not market benchmarks.
create or replace view dash.v_workspace_sov_keyword
with (security_invoker = true) as
select w.workspace_id, w.brand_name,
       s.period_start, s.period_end, s.keyword, s.searches, s.sov_pct, s.loaded_at
from silver.fact_fp_ads s
join dash.cfg_workspace_map w
  on w.platform = 'blinkit'
 and w.scope_kind = 'campaign'
 and w.scope_value = s.campaign_id      -- sov rows carry campaign_id = 'sov'
where s.report_type = 'sov_period' and s.dq_status = 'valid'
order by s.period_end desc, s.sov_pct desc;

comment on view dash.v_workspace_sov_keyword is
  'Keyword Share of Voice, ACCOUNT-SPECIFIC (brand''s own sponsored share from its Blinkit advertiser account). Not a market benchmark.';

-- 4. Workspace-scoped sales (reserved; empty until the sales export arrives) -----
create or replace view dash.v_workspace_overview
with (security_invoker = true) as
select w.workspace_id, w.brand_name, o.*
from dash.overview o
join dash.cfg_workspace_map w
  on w.platform = o.platform
 and w.scope_kind = 'sku'
 and w.scope_value = o.sidnl_id;

comment on view dash.v_workspace_overview is
  'Transactional sales (GMV, net sales, units) scoped to workspaces by sidnl_id mapping. EMPTY until the seller-portal sales export is ingested; published so FastAPI can wire it now. Seed scope_kind=''sku'' rows in cfg_workspace_map when the first sales load lands.';

-- 5. Sanity checks (run after applying) -----------------------------------------
-- select * from dash.cfg_workspace_map order by scope_kind, scope_value;
-- select workspace_id, brand_name, count(*) from dash.v_workspace_ads group by 1,2;
-- select * from dash.v_workspace_sov_keyword;
-- select count(*) from dash.v_workspace_overview;   -- 0 until sales data arrives
-- -- safety: any dash.ads campaign NOT yet mapped (should be empty today):
-- select distinct platform, campaign_id from dash.ads
-- except select platform, scope_value from dash.cfg_workspace_map where scope_kind='campaign';
