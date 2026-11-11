-- dash_012_ads_from_formula_sheet   (needs silver_074)
-- dash.ads, dash.ads_campaign_period and dash.ads_keyword_sov are built ONLY from the formula sheet:
--   rows    = silver.ref_dash_grain   (grain, silver view, key columns)
--   columns = silver.ref_metric_support where dash_table = <table> (dash_column, sql_expr, grain_levels)
-- dash.refresh_formula_table(<table>) deletes the table and inserts every grain in one statement each; a bad formula
-- fails the whole refresh and the previous rows stay (exception block). dash.refresh_ads() runs it for the three tables
-- and records them in dash.refresh_table_state (so they show in dash.v_refresh_status and the portal header).
-- Automation: an upload into public.fp_blinkit_ads reloads silver and dash at once (statement trigger; an error there
-- never blocks the upload), and cron sidnl-fp-ads re-runs both every 10 minutes (formula-sheet edits, missed triggers).
-- silver.check_fp_ads(): bronze = silver, duplicate files agree, dash = silver at every grain, ROAS = platform ROAS,
-- claimables = daily spend, every dash column has a formula-sheet row.

do $preflight$
begin
    if to_regclass('silver.ref_dash_grain') is null or to_regclass('silver.v_fp_ads_daily') is null then
        raise exception 'dash_012 preflight: silver_074 not applied';
    end if;
end $preflight$;

-- ---------------------------------------------------------------- dash.ads: placement grain
drop view if exists dash.v_sov_keyword;
drop index if exists dash.ads_key;
alter table dash.ads drop column if exists report_level;
alter table dash.ads add column if not exists placement      text;
alter table dash.ads add column if not exists subcampaign_id text;
alter table dash.ads add column if not exists match_type     text;
alter table dash.ads add column if not exists pacing_type    text;
alter table dash.ads add column if not exists cpm_bid        numeric(10,2);
alter table dash.ads add column report_level text generated always as (
    case when keyword   is not null then 'keyword'
         when placement is not null then 'placement'
         when sidnl_id  is not null then 'sku'
         else 'campaign' end) stored;
create unique index ads_key on dash.ads (obs_date, platform, campaign_id, keyword, placement, sidnl_id) nulls not distinct;
comment on table dash.ads is 'dash_012: Ads Insights + Keyword Search tabs, per day. report_level keyword (keyword ads), placement (recommendation ads), campaign (= its keyword or placement rows added up, + daily budget and utilisation). Never add rows of different report_level. Every column is one metric of silver.ref_metric_support (dash_table = ''ads''); NULL = not in the source data.';
comment on column dash.ads.cpm is 'Effective CPM = spend / impressions x 1000. The CPM set on the keyword/placement is cpm_bid.';
comment on column dash.ads.kw_volume_monthly is 'Searches of the keyword in the sponsored-SoV report period containing the day. Attribute: never sum across days.';

-- ---------------------------------------------------------------- period tables
create table if not exists dash.ads_campaign_period (
    period_start           date not null,
    period_end             date not null,
    platform               text not null,
    campaign_id            text not null,
    campaign_name          text,
    campaign_type          text,
    total_budget           numeric(14,2),
    claimables             numeric(14,2),
    served_budget_consumed numeric(14,2),
    impressions            bigint,
    budget_utilisation_pct numeric(6,2),
    daily_ad_spend         numeric(14,2),
    daily_impressions      bigint,
    daily_days             integer,
    spend_reconciled       boolean,
    refreshed_at           timestamptz not null default now(),
    primary key (period_start, period_end, platform, campaign_id)
);
alter table dash.ads_campaign_period enable row level security;
comment on table dash.ads_campaign_period is 'dash_012: MTD Claimables per campaign x report period (platform figures) + the same campaign''s daily rows added up inside the period; spend_reconciled = they agree. Columns from silver.ref_metric_support (dash_table = ''ads_campaign_period'').';

create table if not exists dash.ads_keyword_sov (
    period_start      date not null,
    period_end        date not null,
    platform          text not null,
    keyword           text not null,
    searches          bigint,
    sponsored_sov_pct numeric(7,3),
    ad_impressions    bigint,
    ad_spend          numeric(14,2),
    direct_sales      numeric(14,2),
    attributed_sales  numeric(14,2),
    total_roas        numeric(10,2),
    ad_days           integer,
    refreshed_at      timestamptz not null default now(),
    primary key (period_start, period_end, platform, keyword)
);
alter table dash.ads_keyword_sov enable row level security;
comment on table dash.ads_keyword_sov is 'dash_012: sponsored share of voice per keyword x report period (platform figures: searches, SoV %) + the brand''s own keyword-ad totals in the period. Columns from silver.ref_metric_support (dash_table = ''ads_keyword_sov'').';

-- kept for existing readers; now reads dash, not silver
create view dash.v_sov_keyword as
select period_start, period_end, keyword, searches, sponsored_sov_pct as sov_pct, refreshed_at as loaded_at
  from dash.ads_keyword_sov
 order by period_end desc, sponsored_sov_pct desc;

-- ---------------------------------------------------------------- the engine
CREATE OR REPLACE FUNCTION dash.refresh_formula_table(p_table text)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'dash', 'silver', 'pg_temp'
AS $function$
declare g record; v_cols text; v_exprs text; v_k bigint; v_n bigint := 0;
begin
    if not exists (select 1 from silver.ref_dash_grain where dash_table = p_table) then
        raise exception 'refresh_formula_table: % has no grain in silver.ref_dash_grain', p_table;
    end if;
    execute format('delete from dash.%I', p_table);
    for g in select * from silver.ref_dash_grain where dash_table = p_table order by grain_order loop
        select string_agg(format('%I', m.dash_column), ', ' order by m.metric_id),
               string_agg(m.sql_expr, ', ' order by m.metric_id)
          into v_cols, v_exprs
          from silver.ref_metric_support m
         where m.dash_table = p_table and m.sql_expr is not null and g.grain_level = any (m.grain_levels);
        execute format('insert into dash.%I (%s%s) select %s%s from %s f where %s group by %s',
                       p_table, g.key_columns, coalesce(', ' || v_cols, ''), g.key_exprs,
                       coalesce(', ' || v_exprs, ''), g.source_relation, g.filter_sql, g.key_exprs);
        get diagnostics v_k = row_count;
        v_n := v_n + v_k;
    end loop;
    return v_n;
end $function$;
comment on function dash.refresh_formula_table(text) is 'dash_012: rebuilds dash.<p_table> from the formula sheet: one INSERT .. SELECT per grain of silver.ref_dash_grain, columns and formulas from silver.ref_metric_support. Nothing about a metric is written in this function.';

CREATE OR REPLACE FUNCTION dash.refresh_ads()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'dash', 'silver', 'pg_temp'
AS $function$
declare v_t0 timestamptz := clock_timestamp(); v_res jsonb := '{}'; v_t text; v_n bigint;
        v_tables text[] := array['ads', 'ads_campaign_period', 'ads_keyword_sov'];
begin
    begin
        foreach v_t in array v_tables loop
            v_n := dash.refresh_formula_table(v_t);
            v_res := v_res || jsonb_build_object(v_t, v_n);
        end loop;
    exception when others then
        -- the block is rolled back: every table keeps its previous rows
        insert into dash.refresh_table_state (table_name, last_attempt_at, last_status, last_error)
        select t, now(), 'failed', left(sqlerrm, 1000) from unnest(v_tables) t
        on conflict (table_name) do update
           set last_attempt_at = now(), last_status = 'failed', last_error = excluded.last_error;
        return jsonb_build_object('status', 'failed', 'error', sqlerrm, 'sqlstate', sqlstate);
    end;
    insert into dash.refresh_table_state (table_name, last_refreshed_at, row_count, last_attempt_at, last_status,
                                          last_error, gold_attempts, next_retry_at)
    select t, now(), (v_res ->> t)::bigint, now(), 'success', null, 0, null from unnest(v_tables) t
    on conflict (table_name) do update
       set last_refreshed_at = now(), row_count = excluded.row_count, last_attempt_at = now(),
           last_status = 'success', last_error = null, gold_attempts = 0, next_retry_at = null;
    return jsonb_build_object('status', 'success', 'rows', v_res,
                              'ms', round(extract(epoch from clock_timestamp() - v_t0) * 1000));
end $function$;
comment on function dash.refresh_ads() is 'dash_012: rebuilds dash.ads, dash.ads_campaign_period, dash.ads_keyword_sov from the formula sheet (dash.refresh_formula_table). All or nothing: on error the old rows stay and refresh_table_state says failed.';

-- ---------------------------------------------------------------- checks
CREATE OR REPLACE FUNCTION silver.check_fp_ads()
 RETURNS TABLE(check_name text, ok boolean, detail text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'silver', 'dash', 'public', 'pg_temp'
AS $function$
  with
  b_s as (
    select (select count(*) from public.fp_blinkit_ads) b,
           (select count(*) from silver.fact_fp_ads) s,
           (select count(*) from public.fp_blinkit_ads b where not exists
              (select 1 from silver.fact_fp_ads s where s.fp_ads_id = b.id and s.impressions is not distinct from b.impressions
                 and s.budget_consumed is not distinct from b.budget_consumed and s.direct_sales is not distinct from b.direct_sales
                 and s.claimables is not distinct from b.claimables and s.sov_pct is not distinct from b.sov_pct)) diff),
  dup as (
    select count(*) filter (where n_versions > 1) conflicts, count(*) filter (where n_rows > 1) keys_in_two_files
      from (select count(*) n_rows,
                   count(distinct (impressions, budget_consumed, direct_sales, indirect_sales, direct_atc, indirect_atc,
                                   direct_qty, indirect_qty, new_users)) n_versions
              from silver.fact_fp_ads where report_type in ('keyword_daily', 'reco_daily') and dq_status = 'valid'
             group by platform, report_type, obs_date, campaign_id, coalesce(placement, lower(btrim(target_value)))) x),
  lvl as (
    select l.lvl, count(*) filter (where s.k is distinct from d.k) bad, count(*) n
      from (values ('keyword'), ('placement'), ('campaign')) l(lvl)
      cross join lateral (
        select v.campaign_id, sum(v.budget_consumed) sp, sum(v.impressions) im, sum(v.direct_sales) ds,
               sum(v.indirect_sales) isl, sum(v.direct_atc) da, sum(v.direct_qty) dq
          from silver.v_fp_ads_daily v
         where l.lvl = 'campaign' or (l.lvl = 'keyword' and v.report_type = 'keyword_daily')
            or (l.lvl = 'placement' and v.report_type = 'reco_daily')
         group by 1) s0
      cross join lateral (select row(s0.sp, s0.im, s0.ds, s0.isl, s0.da, s0.dq)::text k) s
      left join lateral (
        select row(sum(a.ad_spend), sum(a.impressions), sum(a.direct_sales), sum(a.indirect_sales),
                   sum(a.direct_atc), sum(a.direct_qty_sold))::text k
          from dash.ads a where a.report_level = l.lvl and a.campaign_id = s0.campaign_id) d on true
     group by 1),
  roas as (
    select count(*) filter (where abs(a.direct_roas - v.direct_roas) > 0.01 or abs(a.total_roas - v.total_roas) > 0.01) bad,
           count(*) n
      from dash.ads a
      join silver.v_fp_ads_daily v
        on v.obs_date = a.obs_date and v.platform = a.platform and v.campaign_id = a.campaign_id
       and ((a.report_level = 'keyword' and v.report_type = 'keyword_daily' and v.keyword = a.keyword)
         or (a.report_level = 'placement' and v.report_type = 'reco_daily' and v.placement = a.placement))
     where v.budget_consumed > 0),
  cols as (
    select string_agg(c.table_name || '.' || c.column_name, ', ' order by c.table_name, c.column_name) missing
      from information_schema.columns c
     where c.table_schema = 'dash' and c.table_name in ('ads', 'ads_campaign_period', 'ads_keyword_sov')
       and c.column_name not in ('refreshed_at', 'report_level')
       and not exists (select 1 from silver.ref_dash_grain g where g.dash_table = c.table_name
                          and c.column_name = any (string_to_array(replace(g.key_columns, ' ', ''), ',')))
       and not exists (select 1 from silver.ref_metric_support m where m.dash_table = c.table_name and m.dash_column = c.column_name))
  select 'bronze_equals_silver', b_s.b = b_s.s and b_s.diff = 0,
         format('bronze %s rows, silver %s, differing %s', b_s.b, b_s.s, b_s.diff) from b_s
  union all
  select 'duplicate_files_agree', dup.conflicts = 0,
         format('%s day keys carried by two files, %s with different numbers', dup.keys_in_two_files, dup.conflicts) from dup
  union all
  select 'no_suspect_or_invalid_rows', count(*) = 0,
         coalesce(string_agg(distinct dq_status || ':' || array_to_string(dq_flags, '+'), ', '), 'none')
    from silver.fact_fp_ads where dq_status <> 'valid'
  union all
  select 'dash_ads_equals_silver_' || lvl.lvl, lvl.bad = 0, format('%s campaigns, %s differ', lvl.n, lvl.bad) from lvl
  union all
  select 'roas_equals_platform', roas.bad = 0, format('%s rows with spend, %s differ by > 0.01', roas.n, roas.bad) from roas
  union all
  select 'claimables_equal_daily_spend', coalesce(bool_and(spend_reconciled), true),
         coalesce(string_agg(format('%s: claimables %s vs daily %s', campaign_id, served_budget_consumed, daily_ad_spend), '; '), 'no MTD rows')
    from dash.ads_campaign_period
  union all
  select 'every_dash_column_in_formula_sheet', cols.missing is null, coalesce('missing: ' || cols.missing, 'all mapped') from cols
$function$;
comment on function silver.check_fp_ads() is 'dash_012: proofs for the first-party ads feed. No rows with ok = false = bronze -> silver -> dash is exact.';

-- ---------------------------------------------------------------- automation
CREATE OR REPLACE FUNCTION silver.on_fp_ads_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'silver', 'dash', 'public', 'pg_temp'
AS $function$
begin
    begin
        perform silver.load_fp_ads();
        perform dash.refresh_ads();
    exception when others then
        -- never block an upload; cron sidnl-fp-ads retries in <= 10 minutes
        raise warning 'fp ads refresh after upload failed: %', sqlerrm;
    end;
    return null;
end $function$;
revoke all on function silver.on_fp_ads_change() from public;
comment on function silver.on_fp_ads_change() is 'dash_012: statement trigger on public.fp_blinkit_ads: reload silver + dash right after an upload.';

drop trigger if exists fp_ads_refresh on public.fp_blinkit_ads;
create trigger fp_ads_refresh after insert or update or delete on public.fp_blinkit_ads
    for each statement execute function silver.on_fp_ads_change();

select cron.schedule('sidnl-fp-ads', '*/10 * * * *',
       'set statement_timeout = ''120s''; select silver.load_fp_ads(); select dash.refresh_ads()');

-- ---------------------------------------------------------------- PDF metric catalog
update dash.metric_catalog
   set status = 'computed', gold_table = 'dash.ads', gold_columns = 'ad_spend (+ campaign_budget, budget_utilisation_pct on campaign rows)',
       required_inputs = 'Blinkit ad-console exports (Keyword Targeting, Product Recommendation, MTD Claimables)',
       missing_inputs = null, owner_team = 'client_data',
       notes = 'First-party feed public.fp_blinkit_ads -> silver.fact_fp_ads -> dash.ads via the formula sheet (dash_012).'
 where metric_key = 'ad_spend';
update dash.metric_catalog
   set status = 'computed', gold_table = 'dash.ads, dash.ads_keyword_sov', gold_columns = 'kw_volume_monthly, searches',
       required_inputs = 'Blinkit sponsored SoV export', missing_inputs = null, owner_team = 'client_data',
       notes = 'Searches per keyword per report period, as reported by the platform.'
 where metric_key = 'kw_vol';
insert into dash.metric_catalog (metric_key, pdf_section, section_name, metric_name, formula, status, gold_table,
                                 gold_columns, required_inputs, missing_inputs, owner_team, notes) values
  ('ads_roas', 8, 'Visibility & Keyword Insights', 'Direct / Total ROAS', 'Direct sales / spend ; (direct + indirect sales) / spend',
   'computed', 'dash.ads', 'direct_roas, total_roas', 'Blinkit ad-console exports', null, 'client_data', 'Equals the platform RoAS (silver.check_fp_ads).'),
  ('ads_sales_atc_units', 8, 'Visibility & Keyword Insights', 'Ad-attributed sales, ATC, units, new users', 'SUMs of direct and indirect',
   'computed', 'dash.ads', 'direct_sales, indirect_sales, attributed_sales, direct_atc, indirect_atc, atc, *_qty_sold, new_users_acquired',
   'Blinkit ad-console exports', null, 'client_data', null),
  ('ads_impressions_cpm', 8, 'Visibility & Keyword Insights', 'Ad impressions, effective CPM', 'SUM(impressions) ; spend / impressions x 1000',
   'computed', 'dash.ads', 'impressions, cpm, cpm_bid', 'Blinkit ad-console exports', null, 'client_data', null),
  ('ads_budget_claimables', 8, 'Visibility & Keyword Insights', 'Budget, claimables, budget utilisation', 'Served budget consumed / total budget x 100 (MTD) ; spend / daily budget x 100 (day)',
   'computed', 'dash.ads_campaign_period, dash.ads', 'total_budget, claimables, budget_utilisation_pct, spend_reconciled', 'MTD Claimables sheet', null, 'client_data', null),
  ('sponsored_sov', 8, 'Visibility & Keyword Insights', 'Sponsored SoV (%)', 'As reported by the platform per keyword x period',
   'computed', 'dash.ads_keyword_sov', 'sponsored_sov_pct, searches', 'Blinkit sponsored SoV export', null, 'client_data', null),
  ('ads_clicks_ctr_cpc_aov', 8, 'Visibility & Keyword Insights', 'Clicks, CTR, CPC, AOV, conversion rate', 'Clicks / impressions ; spend / clicks ; sales / orders ; orders / clicks',
   'blocked', 'dash.ads', 'clicks, ctr_pct, cpc, aov, conversion_rate_pct', 'Clicks and orders per ad', 'The Blinkit exports have no clicks and no orders', 'client_data', 'Columns stay NULL.')
on conflict (metric_key) do update set
  formula = excluded.formula, status = excluded.status, gold_table = excluded.gold_table, gold_columns = excluded.gold_columns,
  required_inputs = excluded.required_inputs, missing_inputs = excluded.missing_inputs, owner_team = excluded.owner_team,
  notes = excluded.notes;

-- first build
select silver.load_fp_ads();
select dash.refresh_ads();
