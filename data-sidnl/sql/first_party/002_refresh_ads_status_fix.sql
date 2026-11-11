-- ============================================================================
-- FIX for refresh_ads: dash.refresh_table_state.last_status has a CHECK
-- constraint allowing only 'success'/'failed' — the original function wrote
-- 'ok'. Run this whole file in the Supabase SQL editor, then re-run:
--     select silver.load_fp_ads();   -- only if the Excel loader hasn't run yet
--     select dash.refresh_ads();
-- Also committed to sql/first_party/001_fp_blinkit_ads.sql (amended in place).
-- ============================================================================

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

  -- campaign-level MTD summary: obs_date = latest known ads date
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
