-- silver_074_fp_ads_formula_sheet   (first-party Blinkit ads feed; needs the bronze tables public.fp_blinkit_ads + fp_load_file)
-- Before: public.fp_blinkit_ads (bronze, loaded from the ad-console exports) -> silver.fact_fp_ads by an insert-only
--         silver.load_fp_ads(); dash.refresh_ads() wrote dash.ads with hand-written SQL. Defects found on 2026-11-11:
--           * the same recommendation day was loaded from two files (console + "Report_" export) and SUMMED:
--             campaign 330981 showed spend 32,124.40 / impressions 160,622 / direct sales 73,280 (file: 16,062.20 /
--             80,311 / 36,640);
--           * the MTD claimables rows were written as fake "campaign" day rows on the last date (impressions = month
--             total), and the one for campaign 330981 was silently dropped by ON CONFLICT DO NOTHING;
--           * the daily budget (5,000) was repeated on every keyword row (SUM = 375,000), claimables never reached dash,
--             sponsored SoV only existed as a view over silver, nothing ran on its own (no cron, no trigger);
--           * silver kept rows whose bronze row was deleted and never picked up corrections.
-- After:  the formula sheet silver.ref_metric_support gets dash_table / dash_column / sql_expr / grain_levels:
--         one row per dash column = one metric = its formula. silver.ref_dash_grain says, per dash table, which grains
--         exist (keyword / placement / campaign day, campaign period, keyword period), which silver view feeds each and
--         which key columns it has. dash.refresh_formula_table() (dash_012) builds every dash row from those two tables
--         only: no metric is written by hand anywhere.
--         Silver: fact_fp_ads = one row per bronze row (upsert + delete of vanished rows), platform and file carried,
--         recommendation placement labels of both export formats mapped to one name (silver.ref_ad_placement), MTD
--         period taken from the file name, dq_flags. Views pick ONE row per natural key when two files carry the same
--         day (console export preferred: it has sub-campaign id and budget).
-- Rollback: rollbacks_pending.sql / rollbacks.sql section "silver_074_fp_ads_formula_sheet".

do $preflight$
declare v_missing text;
begin
    select string_agg(v.t || '.' || v.c, ', ' order by v.t, v.c) into v_missing
      from (values ('fp_blinkit_ads','id'),('fp_blinkit_ads','report_type'),('fp_blinkit_ads','obs_date'),
                   ('fp_blinkit_ads','period_start'),('fp_blinkit_ads','period_end'),('fp_blinkit_ads','campaign_id'),
                   ('fp_blinkit_ads','campaign_name'),('fp_blinkit_ads','subcampaign_id'),('fp_blinkit_ads','ad_type'),
                   ('fp_blinkit_ads','target_type'),('fp_blinkit_ads','target_value'),('fp_blinkit_ads','match_type'),
                   ('fp_blinkit_ads','pacing_type'),('fp_blinkit_ads','most_viewed_position'),('fp_blinkit_ads','cpm'),
                   ('fp_blinkit_ads','total_budget'),('fp_blinkit_ads','impressions'),('fp_blinkit_ads','direct_atc'),
                   ('fp_blinkit_ads','indirect_atc'),('fp_blinkit_ads','new_users'),('fp_blinkit_ads','direct_sales'),
                   ('fp_blinkit_ads','indirect_sales'),('fp_blinkit_ads','direct_qty'),('fp_blinkit_ads','indirect_qty'),
                   ('fp_blinkit_ads','budget_consumed'),('fp_blinkit_ads','direct_roas'),('fp_blinkit_ads','total_roas'),
                   ('fp_blinkit_ads','searches'),('fp_blinkit_ads','sov_pct'),('fp_blinkit_ads','claimables'),
                   ('fp_blinkit_ads','served_budget'),('fp_blinkit_ads','source_file'),('fp_blinkit_ads','loaded_at')
           ) v (t, c)
     where not exists (select 1 from information_schema.columns c
                        where c.table_schema = 'public' and c.table_name = v.t and c.column_name = v.c);
    if v_missing is not null then
        raise exception 'silver_074 preflight: bronze columns not found: %', v_missing;
    end if;
end $preflight$;

-- ---------------------------------------------------------------- silver fact: carry what bronze has
alter table silver.fact_fp_ads add column if not exists platform    text not null default 'blinkit';
alter table silver.fact_fp_ads add column if not exists source_file text;
alter table silver.fact_fp_ads add column if not exists pacing_type text;
alter table silver.fact_fp_ads add column if not exists placement   text;
alter table silver.fact_fp_ads add column if not exists dq_flags    text[] not null default '{}';
comment on column silver.fact_fp_ads.platform is 'From the bronze table: public.fp_blinkit_ads holds Blinkit ad-console exports only.';
comment on column silver.fact_fp_ads.placement is 'Recommendation rows: one name for the placement in both export formats (silver.ref_ad_placement). NULL for keyword rows.';
comment on column silver.fact_fp_ads.period_start is 'Period reports. mtd_claimables files carry no period: taken from the file name (<account>_Search_Reports_<YYYY-MM-DD>: month start .. that date).';
comment on table silver.fact_fp_ads is 'silver_074: one row per public.fp_blinkit_ads row (values copied; placement / period / dq added). Report types: keyword_daily, reco_daily, mtd_claimables, sov_period. Read through v_fp_ads_daily / v_fp_ads_campaign_period / v_fp_ads_keyword_period, which keep one row per natural key when two files carry the same data.';

-- ---------------------------------------------------------------- placement names (both export formats)
create table if not exists silver.ref_ad_placement (
    platform  text not null,
    raw_label text not null,
    placement text not null,
    primary key (platform, raw_label)
);
alter table silver.ref_ad_placement enable row level security;
comment on table silver.ref_ad_placement is 'Recommendation-ad placement labels as each export writes them -> one placement name. Console export: "Asset"; Report_ export: "Targeting Type". Pairs proven equal on 2026-11-11: all 70 rows of 2026-10-01..19 carry identical impressions, spend and sales under both labels. An unknown label makes the row suspect (kept out of dash) until it is added here.';
insert into silver.ref_ad_placement (platform, raw_label, placement) values
    ('blinkit', 'Next Product Recommendations',                 'Next Product Recommendations'),
    ('blinkit', 'Next Product Recommendation',                  'Next Product Recommendations'),
    ('blinkit', 'Similar Product Recommendations',              'Similar Product Recommendations'),
    ('blinkit', 'Similar Products Recommendation',              'Similar Product Recommendations'),
    ('blinkit', 'Repeat Order Suggestions - New User Targeting', 'Repeat Order Suggestions - New User Targeting'),
    ('blinkit', 'Repeat Order Suggestion',                      'Repeat Order Suggestions - New User Targeting'),
    ('blinkit', 'Repeat Order Suggestions - Retargeting',       'Repeat Order Suggestions - Retargeting'),
    ('blinkit', 'Retargeting',                                  'Repeat Order Suggestions - Retargeting')
on conflict (platform, raw_label) do update set placement = excluded.placement;

-- ---------------------------------------------------------------- loader: silver = bronze, always
CREATE OR REPLACE FUNCTION silver.load_fp_ads()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'silver', 'public', 'pg_temp'
AS $function$
declare v_up bigint; v_del bigint;
begin
    -- a bronze row that was deleted leaves silver too (silver row = bronze row)
    delete from silver.fact_fp_ads s
     where not exists (select 1 from public.fp_blinkit_ads b where b.id = s.fp_ads_id);
    get diagnostics v_del = row_count;

    insert into silver.fact_fp_ads as s (
        fp_ads_id, platform, source_file, report_type, obs_date, period_start, period_end,
        campaign_id, campaign_name, subcampaign_id, ad_type, target_type, target_value, placement,
        match_type, pacing_type, most_viewed_position, cpm, total_budget, impressions,
        direct_atc, indirect_atc, new_users, direct_sales, indirect_sales, direct_qty, indirect_qty,
        budget_consumed, direct_roas, total_roas, searches, sov_pct, claimables, served_budget,
        dq_status, dq_flags, loaded_at)
    with b as (
        select b.*,
               case when b.report_type = 'mtd_claimables' and b.source_file ~ '\d{4}-\d{2}-\d{2}\.[A-Za-z]+$'
                    then substring(b.source_file from '(\d{4}-\d{2}-\d{2})\.[A-Za-z]+$')::date end as file_date,
               p.placement as mapped_placement
          from public.fp_blinkit_ads b
          left join silver.ref_ad_placement p
            on b.report_type = 'reco_daily' and p.platform = 'blinkit' and p.raw_label = btrim(b.target_value)),
    q as (
        select b.*,
               array_remove(array[
                   case when least(b.impressions, b.direct_atc, b.indirect_atc, b.new_users, b.direct_qty, b.indirect_qty,
                                   b.searches) < 0
                          or least(b.direct_sales, b.indirect_sales, b.budget_consumed, b.cpm, b.total_budget,
                                   b.claimables, b.served_budget, b.sov_pct) < 0 then 'negative_value' end,
                   case when b.report_type in ('keyword_daily', 'reco_daily') and b.obs_date is null then 'no_date' end,
                   case when b.report_type in ('mtd_claimables', 'sov_period')
                         and coalesce(b.period_end, b.file_date) is null then 'no_period' end,
                   case when b.report_type = 'reco_daily' and b.mapped_placement is null then 'placement_unmapped' end,
                   case when b.report_type in ('keyword_daily', 'reco_daily') and b.budget_consumed > 0
                         and abs(b.direct_roas - round(b.direct_sales / b.budget_consumed, 2)) > 0.011
                        then 'platform_direct_roas_differs' end,
                   case when b.report_type in ('keyword_daily', 'reco_daily') and b.budget_consumed > 0
                         and abs(b.total_roas - round((b.direct_sales + b.indirect_sales) / b.budget_consumed, 2)) > 0.011
                        then 'platform_total_roas_differs' end
               ], null) as flags
          from b)
    select q.id, 'blinkit', q.source_file, q.report_type, q.obs_date,
           coalesce(q.period_start, date_trunc('month', q.file_date)::date),
           coalesce(q.period_end, q.file_date),
           q.campaign_id, q.campaign_name, q.subcampaign_id, q.ad_type, q.target_type, q.target_value,
           case when q.report_type = 'reco_daily' then coalesce(q.mapped_placement, btrim(q.target_value)) end,
           q.match_type, q.pacing_type, q.most_viewed_position, q.cpm, q.total_budget, q.impressions,
           q.direct_atc, q.indirect_atc, q.new_users, q.direct_sales, q.indirect_sales, q.direct_qty, q.indirect_qty,
           q.budget_consumed, q.direct_roas, q.total_roas, q.searches, q.sov_pct, q.claimables, q.served_budget,
           case when q.flags && array['negative_value', 'no_date', 'no_period'] then 'invalid'
                when q.flags && array['placement_unmapped'] then 'suspect'
                else 'valid' end,
           q.flags, q.loaded_at
      from q
    on conflict (fp_ads_id) do update set
        platform = excluded.platform, source_file = excluded.source_file, report_type = excluded.report_type,
        obs_date = excluded.obs_date, period_start = excluded.period_start, period_end = excluded.period_end,
        campaign_id = excluded.campaign_id, campaign_name = excluded.campaign_name,
        subcampaign_id = excluded.subcampaign_id, ad_type = excluded.ad_type, target_type = excluded.target_type,
        target_value = excluded.target_value, placement = excluded.placement, match_type = excluded.match_type,
        pacing_type = excluded.pacing_type, most_viewed_position = excluded.most_viewed_position, cpm = excluded.cpm,
        total_budget = excluded.total_budget, impressions = excluded.impressions, direct_atc = excluded.direct_atc,
        indirect_atc = excluded.indirect_atc, new_users = excluded.new_users, direct_sales = excluded.direct_sales,
        indirect_sales = excluded.indirect_sales, direct_qty = excluded.direct_qty,
        indirect_qty = excluded.indirect_qty, budget_consumed = excluded.budget_consumed,
        direct_roas = excluded.direct_roas, total_roas = excluded.total_roas, searches = excluded.searches,
        sov_pct = excluded.sov_pct, claimables = excluded.claimables, served_budget = excluded.served_budget,
        dq_status = excluded.dq_status, dq_flags = excluded.dq_flags, loaded_at = excluded.loaded_at
    where row(s.platform, s.source_file, s.report_type, s.obs_date, s.period_start, s.period_end, s.campaign_id,
              s.campaign_name, s.subcampaign_id, s.ad_type, s.target_type, s.target_value, s.placement, s.match_type,
              s.pacing_type, s.most_viewed_position, s.cpm, s.total_budget, s.impressions, s.direct_atc,
              s.indirect_atc, s.new_users, s.direct_sales, s.indirect_sales, s.direct_qty, s.indirect_qty,
              s.budget_consumed, s.direct_roas, s.total_roas, s.searches, s.sov_pct, s.claimables, s.served_budget,
              s.dq_status, s.dq_flags, s.loaded_at)
          is distinct from
          row(excluded.platform, excluded.source_file, excluded.report_type, excluded.obs_date, excluded.period_start,
              excluded.period_end, excluded.campaign_id, excluded.campaign_name, excluded.subcampaign_id,
              excluded.ad_type, excluded.target_type, excluded.target_value, excluded.placement, excluded.match_type,
              excluded.pacing_type, excluded.most_viewed_position, excluded.cpm, excluded.total_budget,
              excluded.impressions, excluded.direct_atc, excluded.indirect_atc, excluded.new_users,
              excluded.direct_sales, excluded.indirect_sales, excluded.direct_qty, excluded.indirect_qty,
              excluded.budget_consumed, excluded.direct_roas, excluded.total_roas, excluded.searches, excluded.sov_pct,
              excluded.claimables, excluded.served_budget, excluded.dq_status, excluded.dq_flags, excluded.loaded_at);
    get diagnostics v_up = row_count;

    return jsonb_build_object('status', 'ok', 'upserted', v_up, 'deleted', v_del,
                              'total', (select count(*) from silver.fact_fp_ads),
                              'not_valid', (select count(*) from silver.fact_fp_ads where dq_status <> 'valid'));
end $function$;
comment on function silver.load_fp_ads() is 'silver_074: public.fp_blinkit_ads -> silver.fact_fp_ads. Upserts every bronze row (only changed rows are written), deletes silver rows whose bronze row is gone, maps placements, MTD period from file name, dq: invalid = negative value / no date / no period; suspect = unknown placement; flags only = platform ROAS differs from sales / spend.';

-- ---------------------------------------------------------------- one row per natural key (two files can carry the same day)
create or replace view silver.v_fp_ads_daily as
select d.*
  from (select distinct on (f.platform, f.report_type, f.obs_date, f.campaign_id,
                            coalesce(f.placement, lower(btrim(f.target_value))))
               f.fp_ads_id, f.platform, f.report_type, f.obs_date, f.campaign_id, f.campaign_name, f.subcampaign_id,
               f.ad_type, btrim(f.target_value) as keyword, f.placement, f.match_type, f.pacing_type,
               f.most_viewed_position, f.cpm, f.total_budget, f.impressions, f.direct_atc, f.indirect_atc,
               f.new_users, f.direct_sales, f.indirect_sales, f.direct_qty, f.indirect_qty, f.budget_consumed,
               f.direct_roas, f.total_roas, f.source_file
          from silver.fact_fp_ads f
         where f.report_type in ('keyword_daily', 'reco_daily') and f.dq_status = 'valid'
         -- console export first (it has sub-campaign id and daily budget), then the newest upload
         order by f.platform, f.report_type, f.obs_date, f.campaign_id, coalesce(f.placement, lower(btrim(f.target_value))),
                  (f.subcampaign_id is not null) desc, (f.total_budget is not null) desc, f.loaded_at desc, f.fp_ads_id desc
       ) d;
comment on view silver.v_fp_ads_daily is 'silver_074: valid keyword_daily + reco_daily rows, one per platform x report x date x campaign x keyword/placement (console export preferred). Source of dash.ads.';

create or replace view silver.v_fp_ads_keyword_daily as
select v.*,
       (select max(s.searches) from silver.fact_fp_ads s
         where s.report_type = 'sov_period' and s.dq_status = 'valid' and s.platform = v.platform
           and lower(btrim(s.target_value)) = lower(v.keyword)
           and v.obs_date between s.period_start and s.period_end) as kw_searches_period
  from silver.v_fp_ads_daily v
 where v.report_type = 'keyword_daily';
comment on view silver.v_fp_ads_keyword_daily is 'silver_074: keyword rows of v_fp_ads_daily + the keyword''s searches in the sponsored-SoV report period that contains the day (NULL when no SoV report covers it).';

create or replace view silver.v_fp_ads_campaign_period as
select m.*, d.daily_spend, d.daily_impressions, d.daily_days
  from (select distinct on (f.platform, f.campaign_id, f.period_start, f.period_end)
               f.fp_ads_id, f.platform, f.campaign_id, f.campaign_name, f.ad_type, f.period_start, f.period_end,
               f.total_budget, f.claimables, f.served_budget, f.impressions, f.source_file
          from silver.fact_fp_ads f
         where f.report_type = 'mtd_claimables' and f.dq_status = 'valid'
         order by f.platform, f.campaign_id, f.period_start, f.period_end, f.loaded_at desc, f.fp_ads_id desc) m
  left join lateral (
        select sum(v.budget_consumed) as daily_spend, sum(v.impressions) as daily_impressions,
               count(distinct v.obs_date) as daily_days
          from silver.v_fp_ads_daily v
         where v.platform = m.platform and v.campaign_id = m.campaign_id
           and v.obs_date between m.period_start and m.period_end) d on true;
comment on view silver.v_fp_ads_campaign_period is 'silver_074: one MTD claimables row per campaign x period + the sum of that campaign''s daily rows inside the period (to prove claimables = daily spend).';

create or replace view silver.v_fp_ads_keyword_period as
select s.*, d.ad_impressions, d.ad_spend, d.ad_direct_sales, d.ad_indirect_sales, d.ad_days
  from (select distinct on (f.platform, lower(btrim(f.target_value)), f.period_start, f.period_end)
               f.fp_ads_id, f.platform, btrim(f.target_value) as keyword, f.period_start, f.period_end,
               f.searches, f.sov_pct, f.source_file
          from silver.fact_fp_ads f
         where f.report_type = 'sov_period' and f.dq_status = 'valid'
         order by f.platform, lower(btrim(f.target_value)), f.period_start, f.period_end, f.loaded_at desc,
                  f.fp_ads_id desc) s
  left join lateral (
        select sum(v.impressions) as ad_impressions, sum(v.budget_consumed) as ad_spend,
               sum(v.direct_sales) as ad_direct_sales, sum(v.indirect_sales) as ad_indirect_sales,
               count(distinct v.obs_date) as ad_days
          from silver.v_fp_ads_daily v
         where v.report_type = 'keyword_daily' and v.platform = s.platform and lower(v.keyword) = lower(s.keyword)
           and v.obs_date between s.period_start and s.period_end) d on true;
comment on view silver.v_fp_ads_keyword_period is 'silver_074: one sponsored-SoV row per keyword x period + the brand''s own keyword-ad totals inside that period.';

-- ---------------------------------------------------------------- the formula sheet drives dash
alter table silver.ref_metric_support add column if not exists dash_table   text;
alter table silver.ref_metric_support add column if not exists dash_column  text;
alter table silver.ref_metric_support add column if not exists sql_expr     text;
alter table silver.ref_metric_support add column if not exists grain_levels text[];
create unique index if not exists ref_metric_support_dash_column
    on silver.ref_metric_support (dash_table, dash_column) where dash_table is not null;
comment on column silver.ref_metric_support.dash_table is 'silver_074: dash table this metric fills (dash.refresh_formula_table builds the table from these rows).';
comment on column silver.ref_metric_support.dash_column is 'silver_074: the dash column = this metric. One row per column.';
comment on column silver.ref_metric_support.sql_expr is 'silver_074: the formula as an aggregate over the grain''s silver view (alias f). Ratios are ratios of sums, so every grain rolls up correctly. NULL = not in the source data (support not_available): the column stays NULL, never 0.';
comment on column silver.ref_metric_support.grain_levels is 'silver_074: grains (silver.ref_dash_grain.grain_level) the formula applies to; at other grains the column stays NULL.';

create table if not exists silver.ref_dash_grain (
    dash_table      text not null,
    grain_level     text not null,
    grain_order     integer not null,
    source_relation text not null,
    filter_sql      text not null default 'true',
    key_columns     text not null,
    key_exprs       text not null,
    description     text,
    primary key (dash_table, grain_level)
);
alter table silver.ref_dash_grain enable row level security;
comment on table silver.ref_dash_grain is 'silver_074: per formula-driven dash table, each grain it holds: the silver view that feeds it (alias f), its key columns and their expressions (also the GROUP BY). Metric columns come from silver.ref_metric_support.';
insert into silver.ref_dash_grain (dash_table, grain_level, grain_order, source_relation, filter_sql, key_columns, key_exprs, description) values
  ('ads', 'keyword', 1, 'silver.v_fp_ads_keyword_daily', 'true',
   'obs_date, platform, campaign_id, keyword', 'f.obs_date, f.platform, f.campaign_id, f.keyword',
   'one keyword of a keyword-targeted campaign on one day'),
  ('ads', 'placement', 2, 'silver.v_fp_ads_daily', 'f.report_type = ''reco_daily''',
   'obs_date, platform, campaign_id, placement', 'f.obs_date, f.platform, f.campaign_id, f.placement',
   'one placement of a recommendation campaign on one day'),
  ('ads', 'campaign', 3, 'silver.v_fp_ads_daily', 'true',
   'obs_date, platform, campaign_id', 'f.obs_date, f.platform, f.campaign_id',
   'one campaign on one day = its keyword or placement rows added up'),
  ('ads_campaign_period', 'campaign_period', 1, 'silver.v_fp_ads_campaign_period', 'true',
   'period_start, period_end, platform, campaign_id', 'f.period_start, f.period_end, f.platform, f.campaign_id',
   'one campaign over one MTD claimables report period'),
  ('ads_keyword_sov', 'keyword_period', 1, 'silver.v_fp_ads_keyword_period', 'true',
   'period_start, period_end, platform, keyword', 'f.period_start, f.period_end, f.platform, f.keyword',
   'one keyword over one sponsored-SoV report period')
on conflict (dash_table, grain_level) do update set
  grain_order = excluded.grain_order, source_relation = excluded.source_relation, filter_sql = excluded.filter_sql,
  key_columns = excluded.key_columns, key_exprs = excluded.key_exprs, description = excluded.description;

-- the two section-8 rows that were "not_available" now have a feed
update silver.ref_metric_support
   set support = 'direct', silver_source = 'fact_fp_ads.budget_consumed (Estimated Budget Consumed)',
       dash_table = 'ads', dash_column = 'ad_spend', sql_expr = 'sum(f.budget_consumed)',
       grain_levels = array['keyword', 'placement', 'campaign'],
       notes = 'Blinkit ad-console exports (first-party). Spend = Estimated Budget Consumed.'
 where pdf_section = 8 and metric = 'Ad spend';
update silver.ref_metric_support
   set support = 'direct', silver_source = 'fact_fp_ads.searches (sponsored SoV report)',
       dash_table = 'ads', dash_column = 'kw_volume_monthly', sql_expr = 'max(f.kw_searches_period)',
       grain_levels = array['keyword'],
       notes = 'Searches of the keyword in the sponsored-SoV report period that contains the day (2026-10-01..2026-11-01 today). An attribute of the keyword: never add it up across days.'
 where pdf_section = 8 and metric = 'KW VOL (Monthly)';

insert into silver.ref_metric_support (pdf_section, section_name, metric, formula, support, silver_source, notes,
                                       dash_table, dash_column, sql_expr, grain_levels) values
  -- dash.ads: attributes
  (8, 'Visibility & Keyword Insights', 'Ads: campaign name', 'As reported', 'direct', 'fact_fp_ads.campaign_name', null,
   'ads', 'campaign_name', 'max(f.campaign_name)', array['keyword','placement','campaign']),
  (8, 'Visibility & Keyword Insights', 'Ads: campaign type', 'As reported (Product Booster / Recommendation Ads)', 'direct', 'fact_fp_ads.ad_type', null,
   'ads', 'campaign_type', 'max(f.ad_type)', array['keyword','placement','campaign']),
  (8, 'Visibility & Keyword Insights', 'Ads: sub-campaign id', 'As reported', 'direct', 'fact_fp_ads.subcampaign_id', 'Console export only.',
   'ads', 'subcampaign_id', 'max(f.subcampaign_id)', array['placement']),
  (8, 'Visibility & Keyword Insights', 'Ads: match type', 'As reported', 'direct', 'fact_fp_ads.match_type', null,
   'ads', 'match_type', 'max(f.match_type)', array['keyword']),
  (8, 'Visibility & Keyword Insights', 'Ads: pacing type', 'As reported', 'direct', 'fact_fp_ads.pacing_type', null,
   'ads', 'pacing_type', 'max(f.pacing_type)', array['keyword','placement','campaign']),
  (8, 'Visibility & Keyword Insights', 'Ads: bid CPM', 'CPM set on the keyword / placement', 'direct', 'fact_fp_ads.cpm', 'A setting, not a result: see effective CPM.',
   'ads', 'cpm_bid', 'max(f.cpm)', array['keyword','placement']),
  (8, 'Visibility & Keyword Insights', 'Ads: most viewed position', 'As reported', 'direct', 'fact_fp_ads.most_viewed_position', 'Keyword ads only.',
   'ads', 'most_viewed_position', 'max(f.most_viewed_position)', array['keyword']),
  -- dash.ads: measures
  (8, 'Visibility & Keyword Insights', 'Ads: impressions', 'SUM(impressions)', 'direct', 'fact_fp_ads.impressions', null,
   'ads', 'impressions', 'sum(f.impressions)', array['keyword','placement','campaign']),
  (8, 'Visibility & Keyword Insights', 'Ads: effective CPM', 'Spend / impressions x 1000', 'derived', 'budget_consumed, impressions', null,
   'ads', 'cpm', 'round(sum(f.budget_consumed) * 1000 / nullif(sum(f.impressions), 0), 2)', array['keyword','placement','campaign']),
  (8, 'Visibility & Keyword Insights', 'Ads: direct sales', 'SUM(direct sales)', 'direct', 'fact_fp_ads.direct_sales', null,
   'ads', 'direct_sales', 'sum(f.direct_sales)', array['keyword','placement','campaign']),
  (8, 'Visibility & Keyword Insights', 'Ads: indirect sales', 'SUM(indirect sales)', 'direct', 'fact_fp_ads.indirect_sales', null,
   'ads', 'indirect_sales', 'sum(f.indirect_sales)', array['keyword','placement','campaign']),
  (8, 'Visibility & Keyword Insights', 'Ads: attributed sales', 'Direct sales + indirect sales', 'derived', 'direct_sales, indirect_sales', null,
   'ads', 'attributed_sales', 'sum(f.direct_sales) + sum(f.indirect_sales)', array['keyword','placement','campaign']),
  (8, 'Visibility & Keyword Insights', 'Ads: direct ROAS', 'Direct sales / spend', 'derived', 'direct_sales, budget_consumed', 'Equals the platform''s Direct RoAS (checked by silver.check_fp_ads).',
   'ads', 'direct_roas', 'round(sum(f.direct_sales) / nullif(sum(f.budget_consumed), 0), 2)', array['keyword','placement','campaign']),
  (8, 'Visibility & Keyword Insights', 'Ads: total ROAS', '(Direct + indirect sales) / spend', 'derived', 'direct_sales, indirect_sales, budget_consumed', 'Equals the platform''s Total RoAS (checked by silver.check_fp_ads).',
   'ads', 'total_roas', 'round((sum(f.direct_sales) + sum(f.indirect_sales)) / nullif(sum(f.budget_consumed), 0), 2)', array['keyword','placement','campaign']),
  (8, 'Visibility & Keyword Insights', 'Ads: new users acquired', 'SUM(new users)', 'direct', 'fact_fp_ads.new_users', null,
   'ads', 'new_users_acquired', 'sum(f.new_users)', array['keyword','placement','campaign']),
  (8, 'Visibility & Keyword Insights', 'Ads: direct ATC', 'SUM(direct add-to-carts)', 'direct', 'fact_fp_ads.direct_atc', null,
   'ads', 'direct_atc', 'sum(f.direct_atc)', array['keyword','placement','campaign']),
  (8, 'Visibility & Keyword Insights', 'Ads: indirect ATC', 'SUM(indirect add-to-carts)', 'direct', 'fact_fp_ads.indirect_atc', null,
   'ads', 'indirect_atc', 'sum(f.indirect_atc)', array['keyword','placement','campaign']),
  (8, 'Visibility & Keyword Insights', 'Ads: ATC', 'Direct ATC + indirect ATC', 'derived', 'direct_atc, indirect_atc', null,
   'ads', 'atc', 'sum(f.direct_atc) + sum(f.indirect_atc)', array['keyword','placement','campaign']),
  (8, 'Visibility & Keyword Insights', 'Ads: direct units sold', 'SUM(direct quantities sold)', 'direct', 'fact_fp_ads.direct_qty', null,
   'ads', 'direct_qty_sold', 'sum(f.direct_qty)', array['keyword','placement','campaign']),
  (8, 'Visibility & Keyword Insights', 'Ads: indirect units sold', 'SUM(indirect quantities sold)', 'direct', 'fact_fp_ads.indirect_qty', null,
   'ads', 'indirect_qty_sold', 'sum(f.indirect_qty)', array['keyword','placement','campaign']),
  (8, 'Visibility & Keyword Insights', 'Ads: units sold', 'Direct + indirect units', 'derived', 'direct_qty, indirect_qty', null,
   'ads', 'total_qty_sold', 'sum(f.direct_qty) + sum(f.indirect_qty)', array['keyword','placement','campaign']),
  (8, 'Visibility & Keyword Insights', 'Ads: daily campaign budget', 'Campaign daily budget (Total Budget, DAILY pacing)', 'direct', 'fact_fp_ads.total_budget', 'Console export only; one value per campaign-day (it repeats on every keyword/placement row, so it lives on campaign rows only).',
   'ads', 'campaign_budget', 'max(f.total_budget)', array['campaign']),
  (8, 'Visibility & Keyword Insights', 'Ads: budget utilisation (%)', 'Spend / daily budget x 100', 'derived', 'budget_consumed, total_budget', null,
   'ads', 'budget_utilisation_pct', 'round(sum(f.budget_consumed) * 100 / nullif(max(f.total_budget), 0), 2)', array['campaign']),
  -- dash.ads: columns the exports do not have (stay NULL, never 0)
  (8, 'Visibility & Keyword Insights', 'Ads: clicks', 'SUM(clicks)', 'not_available', null, 'Blinkit ad exports report impressions and add-to-carts, no clicks.', 'ads', 'clicks', null, null),
  (8, 'Visibility & Keyword Insights', 'Ads: reach', 'Unique users reached', 'not_available', null, 'Not in the exports.', 'ads', 'reach', null, null),
  (8, 'Visibility & Keyword Insights', 'Ads: CTR (%)', 'Clicks / impressions x 100', 'not_available', null, 'Needs clicks.', 'ads', 'ctr_pct', null, null),
  (8, 'Visibility & Keyword Insights', 'Ads: CPC', 'Spend / clicks', 'not_available', null, 'Needs clicks.', 'ads', 'cpc', null, null),
  (8, 'Visibility & Keyword Insights', 'Ads: AOV', 'Attributed sales / orders', 'not_available', null, 'Exports give units, not orders.', 'ads', 'aov', null, null),
  (8, 'Visibility & Keyword Insights', 'Ads: conversion rate (%)', 'Orders / clicks x 100', 'not_available', null, 'Needs clicks and orders.', 'ads', 'conversion_rate_pct', null, null),
  (8, 'Visibility & Keyword Insights', 'Ads: keyword rank', 'Organic rank of the brand on the keyword', 'not_available', null, 'Not in the exports (see dash.visibility for scraped ranks).', 'ads', 'keyword_rank', null, null),
  (8, 'Visibility & Keyword Insights', 'Ads: keyword opportunity', 'Rule on search volume vs SoV', 'not_available', null, 'No agreed rule yet; not invented.', 'ads', 'keyword_opportunity', null, null),
  (8, 'Visibility & Keyword Insights', 'Ads: campaign status', 'As reported', 'not_available', null, 'Not in the exports.', 'ads', 'campaign_status', null, null),
  (8, 'Visibility & Keyword Insights', 'Ads: campaign on', 'As reported', 'not_available', null, 'Not in the exports (a day without impressions is not proof the campaign was off).', 'ads', 'is_campaign_on', null, null),
  (8, 'Visibility & Keyword Insights', 'Ads: SKU (SI id)', 'Advertised product', 'not_available', null, 'The exports name no product, so ads cannot be joined to SI ids yet.', 'ads', 'sidnl_id', null, null),
  -- dash.ads_campaign_period
  (8, 'Visibility & Keyword Insights', 'Ads MTD: campaign name', 'As reported', 'direct', 'fact_fp_ads.campaign_name', null,
   'ads_campaign_period', 'campaign_name', 'max(f.campaign_name)', array['campaign_period']),
  (8, 'Visibility & Keyword Insights', 'Ads MTD: campaign type', 'As reported', 'direct', 'fact_fp_ads.ad_type', null,
   'ads_campaign_period', 'campaign_type', 'max(f.ad_type)', array['campaign_period']),
  (8, 'Visibility & Keyword Insights', 'Ads MTD: total budget', 'As reported (MTD Claimables)', 'direct', 'fact_fp_ads.total_budget', null,
   'ads_campaign_period', 'total_budget', 'sum(f.total_budget)', array['campaign_period']),
  (8, 'Visibility & Keyword Insights', 'Ads MTD: claimables', 'As reported (MTD Claimables)', 'direct', 'fact_fp_ads.claimables', null,
   'ads_campaign_period', 'claimables', 'sum(f.claimables)', array['campaign_period']),
  (8, 'Visibility & Keyword Insights', 'Ads MTD: served budget consumed', 'As reported (MTD Claimables)', 'direct', 'fact_fp_ads.served_budget', null,
   'ads_campaign_period', 'served_budget_consumed', 'sum(f.served_budget)', array['campaign_period']),
  (8, 'Visibility & Keyword Insights', 'Ads MTD: impressions', 'As reported (MTD Claimables)', 'direct', 'fact_fp_ads.impressions', null,
   'ads_campaign_period', 'impressions', 'sum(f.impressions)', array['campaign_period']),
  (8, 'Visibility & Keyword Insights', 'Ads MTD: budget utilisation (%)', 'Served budget consumed / total budget x 100', 'derived', 'served_budget, total_budget', null,
   'ads_campaign_period', 'budget_utilisation_pct', 'round(sum(f.served_budget) * 100 / nullif(sum(f.total_budget), 0), 2)', array['campaign_period']),
  (8, 'Visibility & Keyword Insights', 'Ads MTD: spend from daily rows', 'SUM(daily spend) inside the period', 'derived', 'v_fp_ads_daily.budget_consumed', null,
   'ads_campaign_period', 'daily_ad_spend', 'sum(f.daily_spend)', array['campaign_period']),
  (8, 'Visibility & Keyword Insights', 'Ads MTD: impressions from daily rows', 'SUM(daily impressions) inside the period', 'derived', 'v_fp_ads_daily.impressions', null,
   'ads_campaign_period', 'daily_impressions', 'sum(f.daily_impressions)', array['campaign_period']),
  (8, 'Visibility & Keyword Insights', 'Ads MTD: days with daily rows', 'COUNT(distinct day) inside the period', 'derived', 'v_fp_ads_daily.obs_date', null,
   'ads_campaign_period', 'daily_days', 'max(f.daily_days)', array['campaign_period']),
  (8, 'Visibility & Keyword Insights', 'Ads MTD: claimables reconcile', '|served budget consumed - daily spend| <= 0.05', 'derived', 'served_budget, daily spend', 'false = the daily rows do not add up to the platform''s month figure.',
   'ads_campaign_period', 'spend_reconciled', 'bool_and(abs(f.served_budget - f.daily_spend) <= 0.05)', array['campaign_period']),
  -- dash.ads_keyword_sov
  (8, 'Visibility & Keyword Insights', 'Sponsored SoV: searches', 'As reported (Searches)', 'direct', 'fact_fp_ads.searches', null,
   'ads_keyword_sov', 'searches', 'sum(f.searches)', array['keyword_period']),
  (8, 'Visibility & Keyword Insights', 'Sponsored SoV (%)', 'As reported (Share of Voice %): brand share of sponsored impressions on the keyword', 'direct', 'fact_fp_ads.sov_pct', 'Platform figure; the market denominator is not in the export, so it cannot be recomputed.',
   'ads_keyword_sov', 'sponsored_sov_pct', 'max(f.sov_pct)', array['keyword_period']),
  (8, 'Visibility & Keyword Insights', 'Sponsored SoV: own ad impressions', 'SUM(keyword-ad impressions) inside the period', 'derived', 'v_fp_ads_daily.impressions', null,
   'ads_keyword_sov', 'ad_impressions', 'sum(f.ad_impressions)', array['keyword_period']),
  (8, 'Visibility & Keyword Insights', 'Sponsored SoV: own ad spend', 'SUM(keyword-ad spend) inside the period', 'derived', 'v_fp_ads_daily.budget_consumed', null,
   'ads_keyword_sov', 'ad_spend', 'sum(f.ad_spend)', array['keyword_period']),
  (8, 'Visibility & Keyword Insights', 'Sponsored SoV: own ad direct sales', 'SUM(keyword-ad direct sales) inside the period', 'derived', 'v_fp_ads_daily.direct_sales', null,
   'ads_keyword_sov', 'direct_sales', 'sum(f.ad_direct_sales)', array['keyword_period']),
  (8, 'Visibility & Keyword Insights', 'Sponsored SoV: own ad attributed sales', 'Direct + indirect keyword-ad sales inside the period', 'derived', 'v_fp_ads_daily', null,
   'ads_keyword_sov', 'attributed_sales', 'sum(f.ad_direct_sales) + sum(f.ad_indirect_sales)', array['keyword_period']),
  (8, 'Visibility & Keyword Insights', 'Sponsored SoV: own ad total ROAS', 'Attributed sales / spend inside the period', 'derived', 'v_fp_ads_daily', null,
   'ads_keyword_sov', 'total_roas', 'round((sum(f.ad_direct_sales) + sum(f.ad_indirect_sales)) / nullif(sum(f.ad_spend), 0), 2)', array['keyword_period']),
  (8, 'Visibility & Keyword Insights', 'Sponsored SoV: days with keyword ads', 'COUNT(distinct day) inside the period', 'derived', 'v_fp_ads_daily.obs_date', null,
   'ads_keyword_sov', 'ad_days', 'max(f.ad_days)', array['keyword_period'])
on conflict (pdf_section, metric) do update set
  formula = excluded.formula, support = excluded.support, silver_source = excluded.silver_source, notes = excluded.notes,
  dash_table = excluded.dash_table, dash_column = excluded.dash_column, sql_expr = excluded.sql_expr,
  grain_levels = excluded.grain_levels;
