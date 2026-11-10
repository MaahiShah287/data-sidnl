-- Rollback for dash_008_brand_scorecard (views only; no data).
drop view if exists dash.v_brand_scorecard_latest;
drop view if exists dash.v_brand_scorecard;
