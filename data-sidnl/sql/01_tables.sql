-- data-sidnl schema, part 1 of 3: schemas, types, sequences, tables, constraints, indexes, row-level security, comments
-- GENERATED from the live Supabase database by `python sidnl.py export-schema`. Do not edit by hand.
-- Documentation and recovery baseline only: the objects already exist in production; never apply this file there.
-- Recovery on an empty database: apply 01, 02, 03 in order, then run `select silver.run_pipeline(true, 'rebuild')`
-- to rebuild silver from bronze, then `select silver.run_gold_pending()` to rebuild dash.

create schema if not exists silver;
create schema if not exists dash;
create schema if not exists ops;

create type silver.match_feat as (name_clean text, brand text, size_value numeric, size_unit text, pack_count integer, variant_key text, cat_l1 text, cat_l2 text, cat_l3 text);

create type silver.pack_t as (size_value numeric, size_unit text, pack_count integer);

create type silver.score_t as (score numeric, name_sim numeric, brand_sim numeric, size_sim numeric, variant_sim numeric, category_sim numeric, rule_ok boolean, rule_reason text);

create sequence if not exists ops.cron_alert_log_alert_id_seq as bigint increment by 1 minvalue 1 maxvalue 9223372036854775807 start with 1 cache 1;

create sequence if not exists ops.dq_result_dq_id_seq as bigint increment by 1 minvalue 1 maxvalue 9223372036854775807 start with 1 cache 1;

create sequence if not exists ops.pipeline_job_job_id_seq as bigint increment by 1 minvalue 1 maxvalue 9223372036854775807 start with 1 cache 1;

create sequence if not exists ops.storage_alert_log_alert_id_seq as bigint increment by 1 minvalue 1 maxvalue 9223372036854775807 start with 1 cache 1;

create sequence if not exists silver.sidnl_id_seq as bigint increment by 1 minvalue 1 maxvalue 9223372036854775807 start with 1 cache 1;

create table if not exists dash.ads (
    obs_date date not null,
    platform text not null,
    campaign_id text not null,
    keyword text,
    sidnl_id text,
    report_level text generated always as (
CASE
    WHEN (keyword IS NOT NULL) THEN 'keyword'::text
    WHEN (sidnl_id IS NOT NULL) THEN 'sku'::text
    ELSE 'campaign'::text
END) stored,
    campaign_name text,
    campaign_type text,
    campaign_status text,
    is_campaign_on boolean,
    campaign_budget numeric(14,2),
    budget_utilisation_pct numeric(6,2),
    ad_spend numeric(14,2),
    impressions bigint,
    clicks bigint,
    reach bigint,
    ctr_pct numeric(7,3),
    cpc numeric(10,2),
    cpm numeric(10,2),
    direct_sales numeric(14,2),
    indirect_sales numeric(14,2),
    attributed_sales numeric(14,2),
    direct_roas numeric(10,2),
    total_roas numeric(10,2),
    aov numeric(12,2),
    new_users_acquired bigint,
    direct_atc bigint,
    indirect_atc bigint,
    atc bigint,
    conversion_rate_pct numeric(7,3),
    direct_qty_sold bigint,
    indirect_qty_sold bigint,
    total_qty_sold bigint,
    most_viewed_position integer,
    keyword_rank integer,
    kw_volume_monthly bigint,
    keyword_opportunity text,
    refreshed_at timestamp with time zone default now() not null
);

create table if not exists dash.availability (
    obs_date date not null,
    platform text not null,
    city_slug text not null,
    sidnl_id text not null,
    store_key integer,
    ds_eligible_stores integer default 0 not null,
    ds_listed_stores integer default 0 not null,
    ds_listing_pct numeric(6,2),
    osa_eligible_obs integer default 0 not null,
    osa_available_obs integer default 0 not null,
    osa_pct numeric(6,2),
    osa_in_ls_eligible_obs integer default 0 not null,
    osa_in_ls_available_obs integer default 0 not null,
    osa_in_ls_pct numeric(6,2),
    in_stock_stores integer default 0 not null,
    out_of_stock_stores integer default 0 not null,
    low_stock_stores integer default 0 not null,
    inventory_fe bigint,
    inventory_fe_capped_stores integer default 0 not null,
    inventory_be bigint,
    inventory_fe_be bigint,
    drr numeric(12,2),
    doi_fe numeric(10,1),
    doi_be numeric(10,1),
    doi_fe_be numeric(10,1),
    is_critical boolean,
    priority text,
    potential_sales_loss numeric(14,2),
    last_observed_at timestamp with time zone,
    refreshed_at timestamp with time zone default now() not null
);

create table if not exists dash.cfg_sku (
    platform text not null,
    platform_product_id text not null,
    brand_key text not null,
    is_target boolean default true not null,
    threshold_sp numeric,
    notes text
);

create table if not exists dash.cfg_threshold (
    key text not null,
    value numeric,
    value_text text,
    description text not null,
    is_confirmed boolean default false not null,
    updated_at timestamp with time zone default now() not null
);

create table if not exists dash.dim_brand (
    brand_key text not null,
    brand_name text,
    company_name text,
    is_client boolean default false not null
);

create table if not exists dash.dim_category (
    platform text not null,
    l1_id text not null,
    l2_id text not null,
    l1_name text,
    l2_name text
);

create table if not exists dash.dim_city (
    city_slug text not null,
    city_name text,
    state text
);

create table if not exists dash.dim_date (
    date_key date not null,
    year smallint,
    quarter smallint,
    month smallint,
    month_name text,
    week_of_year smallint,
    day_of_week smallint,
    is_weekend boolean
);

create table if not exists dash.dim_platform (
    platform text not null
);

create table if not exists dash.dim_product (
    product_key integer not null,
    platform text not null,
    platform_product_id text not null,
    brand_key text,
    product_name text,
    variant text,
    pack_raw text,
    catalog_product_id bigint,
    category_path text,
    sidnl_id text
);

create table if not exists dash.dim_sidnl (
    sidnl_id text not null,
    brand_key text,
    canonical_name text,
    variant text,
    size_value numeric,
    size_unit text,
    pack_count integer,
    category_path text
);

create table if not exists dash.dim_store (
    store_key integer not null,
    platform text not null,
    store_name text,
    city_slug text
);

create table if not exists dash.metric_catalog (
    metric_key text not null,
    pdf_section integer not null,
    section_name text not null,
    metric_name text not null,
    formula text not null,
    status text not null,
    gold_table text,
    gold_columns text,
    required_inputs text,
    missing_inputs text,
    owner_team text,
    notes text
);

create table if not exists dash.overview (
    obs_date date not null,
    platform text not null,
    city_slug text not null,
    sidnl_id text not null,
    gmv numeric(14,2),
    net_sales numeric(14,2),
    units_sold bigint,
    avg_selling_price numeric(12,2),
    category_sales numeric(16,2),
    market_share_pct numeric(7,3),
    est_market_size numeric(16,2),
    contribution_margin numeric(14,2),
    contribution_margin_pct numeric(7,2),
    refreshed_at timestamp with time zone default now() not null
);

create table if not exists dash.pricing (
    obs_date date not null,
    platform text not null,
    city_slug text not null,
    sidnl_id text not null,
    stores_observed integer not null,
    mrp numeric(12,2),
    selling_price numeric(12,2),
    min_selling_price numeric(12,2),
    max_selling_price numeric(12,2),
    discount_amount numeric(12,2),
    discount_pct numeric(6,2),
    weighted_discount_pct numeric(6,2),
    price_per_100g numeric(12,2),
    price_vs_national_pct numeric(7,2),
    price_gap_vs_lowest_marketplace_pct numeric(7,2),
    price_gap_vs_reference_pct numeric(7,2),
    is_parity_break boolean,
    threshold_sp numeric(12,2),
    threshold_diff numeric(12,2),
    sp_change_pct numeric(7,2),
    discount_change_pts numeric(6,2),
    refreshed_at timestamp with time zone default now() not null
);

create table if not exists dash.refresh_state (
    key text not null,
    value text,
    updated_at timestamp with time zone default now() not null
);

create table if not exists dash.refresh_table_state (
    table_name text not null,
    last_refreshed_at timestamp with time zone,
    last_run_id bigint,
    row_count bigint,
    last_attempt_at timestamp with time zone,
    last_attempt_run_id bigint,
    last_status text,
    last_error text,
    gold_attempts integer default 0 not null,
    next_retry_at timestamp with time zone
);

create table if not exists dash.supply (
    platform text not null,
    po_number text not null,
    sidnl_id text not null,
    invoice_id text,
    warehouse_code text,
    city_slug text,
    po_status text,
    is_open boolean,
    is_overdue boolean,
    priority text,
    is_critical_sku boolean,
    potential_sales_loss numeric(14,2),
    created_date date,
    scheduled_date date,
    expiry_date date,
    grn_date date,
    po_units bigint,
    po_amount numeric(14,2),
    grn_units bigint,
    grn_amount numeric(14,2),
    fulfilment_gap bigint,
    fill_rate_pct numeric(6,2),
    deficit_pct numeric(6,2),
    delivery_time_days integer,
    delivery_delay_days integer,
    scheduled_lead_time_days integer,
    invoice_date date,
    invoice_qty bigint,
    invoice_amount_incl_tax numeric(14,2),
    invoice_status text,
    due_date date,
    credit_days integer,
    due_status text,
    payment_date date,
    payment_amount numeric(14,2),
    advance_paid numeric(14,2),
    tds_amount numeric(14,2),
    approved_amount numeric(14,2),
    amount_payable numeric(14,2),
    grn_qty_diff bigint,
    grn_amount_diff numeric(14,2),
    debit_note_id text,
    dn_qty bigint,
    dn_amount_incl_tax numeric(14,2),
    edi_document_code text,
    edi_direction text,
    edi_partner text,
    edi_received_at timestamp with time zone,
    edi_processed_at timestamp with time zone,
    edi_status text,
    edi_error_category text,
    refreshed_at timestamp with time zone default now() not null
);

create table if not exists dash.visibility (
    obs_date date not null,
    platform text not null,
    city_slug text not null,
    search_type text not null,
    search_term text not null,
    sidnl_id text not null,
    stores_scanned integer not null,
    stores_listed integer not null,
    listing_coverage_pct numeric(6,2),
    impressions integer not null,
    organic_impressions integer not null,
    paid_impressions integer not null,
    top_of_search_impressions integer not null,
    top_of_search_organic_impressions integer not null,
    top_of_search_paid_impressions integer not null,
    best_search_rank integer,
    avg_search_rank numeric(8,2),
    avg_organic_rank numeric(8,2),
    share_of_voice_pct numeric(7,3),
    organic_sov_pct numeric(7,3),
    paid_sov_pct numeric(7,3),
    top_of_search_sov_pct numeric(7,3),
    top_of_search_organic_sov_pct numeric(7,3),
    top_of_search_paid_sov_pct numeric(7,3),
    refreshed_at timestamp with time zone default now() not null
);

create table if not exists ops.backup_silver_057 (
    product_key integer,
    first_seen_at timestamp with time zone
);

create table if not exists ops.cron_alert_log (
    alert_id bigint default nextval('ops.cron_alert_log_alert_id_seq'::regclass) not null,
    alerted_at timestamp with time zone default now() not null,
    jobname text not null,
    level text not null,
    consecutive_failures integer,
    last_failure_message text
);

create table if not exists ops.dead_letter (
    dl_id bigint generated always as identity not null,
    source_table text not null,
    bronze_id bigint not null,
    platform text,
    l1_id text,
    l2_id text,
    platform_product_id text,
    reason text,
    sqlstate text,
    first_seen_at timestamp with time zone default now() not null,
    last_seen_at timestamp with time zone default now() not null,
    retry_count integer default 0 not null,
    last_tried_at timestamp with time zone,
    next_retry_at timestamp with time zone default now() not null,
    status text default 'open'::text not null,
    resolved_at timestamp with time zone,
    resolved_by text,
    note text
);

create table if not exists ops.dq_result (
    dq_id bigint default nextval('ops.dq_result_dq_id_seq'::regclass) not null,
    run_id bigint,
    checked_at timestamp with time zone default now() not null,
    check_name text not null,
    severity text not null,
    scope text not null,
    violations bigint not null,
    total bigint,
    ok boolean not null,
    blocks boolean not null,
    detail text
);

create table if not exists ops.etl_run (
    run_id bigint generated always as identity not null,
    brand_key text not null,
    started_at timestamp with time zone default now() not null,
    finished_at timestamp with time zone,
    status text default 'running'::text not null,
    stats jsonb default '{}'::jsonb not null,
    error text
);

create table if not exists ops.freshness_cursor (
    source_table text not null,
    last_id bigint default 0 not null,
    updated_at timestamp with time zone default now() not null
);

create table if not exists ops.freshness_event (
    event_id bigint generated always as identity not null,
    at timestamp with time zone default now() not null,
    platform text not null,
    source_type text not null,
    from_status text,
    to_status text not null,
    last_ok_at timestamp with time zone
);

create table if not exists ops.freshness_override (
    platform text not null,
    source_type text not null,
    expected boolean default true not null,
    fresh_within_hours integer,
    note text
);

create table if not exists ops.freshness_state (
    platform text not null,
    source_type text not null,
    last_ok_at timestamp with time zone,
    last_attempt_at timestamp with time zone,
    last_failed_at timestamp with time zone,
    last_status text,
    status_since timestamp with time zone,
    updated_at timestamp with time zone default now() not null
);

create table if not exists ops.function_backup (
    fn text not null,
    tag text not null,
    definition text not null,
    saved_at timestamp with time zone default now() not null
);

create table if not exists ops.pipeline_job (
    job_id bigint default nextval('ops.pipeline_job_job_id_seq'::regclass) not null,
    job_type text not null,
    job_date date,
    trigger text,
    force boolean default false not null,
    status text default 'queued'::text not null,
    attempt integer default 0 not null,
    max_attempts integer default 5 not null,
    requested_at timestamp with time zone default now() not null,
    next_attempt_at timestamp with time zone,
    finished_at timestamp with time zone,
    run_id bigint,
    failed_stage text,
    error_class text,
    last_error text,
    last_sqlstate text,
    lock_waits integer default 0 not null,
    note text
);

create table if not exists ops.pipeline_run (
    run_id bigint generated always as identity not null,
    started_at timestamp with time zone default now() not null,
    finished_at timestamp with time zone,
    trigger text not null,
    status text default 'running'::text not null,
    new_data jsonb default '{}'::jsonb not null,
    steps jsonb default '{}'::jsonb not null,
    gold_status text,
    gold_error text,
    gold_seconds numeric,
    dq jsonb,
    watermarks_advanced jsonb,
    job_id bigint,
    attempt integer,
    shelf_rows_inserted bigint,
    shelf_rows_updated bigint,
    rows_rejected bigint,
    failed_stage text,
    error_message text,
    gold_attempts integer default 0 not null,
    gold_next_at timestamp with time zone
);

create table if not exists ops.reconciliation_log (
    recon_id bigint generated always as identity not null,
    run_at timestamp with time zone default now() not null,
    check_name text not null,
    status text not null,
    rows_checked bigint,
    mismatches bigint,
    detail jsonb
);

create table if not exists ops.storage_alert_log (
    alert_id bigint default nextval('ops.storage_alert_log_alert_id_seq'::regclass) not null,
    alerted_at timestamp with time zone default now() not null,
    level text not null,
    used_bytes bigint,
    plan_bytes bigint,
    used_pct numeric,
    db_bytes bigint,
    wal_bytes bigint,
    message text
);

create table if not exists ops.storage_snapshot (
    snapshot_date date not null,
    relation text not null,
    total_bytes bigint not null,
    table_bytes bigint,
    index_bytes bigint,
    live_rows bigint,
    dead_rows bigint,
    db_bytes bigint,
    taken_at timestamp with time zone default now() not null
);

create table if not exists ops.store_city_filled (
    store_key integer not null,
    source_store_id integer not null,
    city_slug text not null,
    snapshots integer not null,
    filled_at timestamp with time zone default now() not null
);

create table if not exists silver.brand_scope (
    brand_key text not null,
    brand_name text not null,
    company_name text,
    raw_brand_aliases text[] default '{}'::text[] not null,
    is_enabled boolean default true not null,
    created_at timestamp with time zone default now() not null,
    scope_source text default 'client'::text not null
);

create table if not exists silver.brand_string_registry (
    raw_brand text not null,
    first_seen_at timestamp with time zone default now() not null
);

create table if not exists silver.canonical_product (
    sidnl_id text not null,
    brand_key text not null,
    canonical_name text not null,
    name_clean text,
    variant text,
    variant_key text,
    product_type text,
    size_value numeric,
    size_unit text,
    pack_count integer default 1 not null,
    category_l1 text,
    category_l2 text,
    category_l3 text,
    anchor_product_key integer,
    created_method text default 'auto'::text not null,
    is_active boolean default true not null,
    merged_into text,
    created_at timestamp with time zone default now() not null
);

create table if not exists silver.category_scope (
    platform text not null,
    l1_id text not null,
    l2_id text not null,
    l1_name text,
    l2_name text,
    is_enabled boolean default true not null,
    created_at timestamp with time zone default now() not null,
    last_loaded_id bigint,
    last_loaded_at timestamp with time zone,
    last_status text,
    last_error text,
    consecutive_failures integer default 0 not null
);

create table if not exists silver.dim_brand (
    brand_key text not null,
    brand_name text not null,
    company_name text,
    is_tracked boolean default true not null
);

create table if not exists silver.dim_category (
    category_key integer generated always as identity not null,
    platform text not null,
    l1_id text,
    l1_name text,
    l2_id text,
    l2_name text,
    l3_id text,
    l3_name text,
    category_path text generated always as (((l1_name || COALESCE((' > '::text || l2_name), ''::text)) || COALESCE((' > '::text || l3_name), ''::text))) stored
);

create table if not exists silver.dim_city (
    city_slug text not null,
    city_name text not null,
    state text,
    center_lat double precision,
    center_lon double precision
);

create table if not exists silver.dim_platform (
    platform text not null,
    platform_name text not null,
    is_test boolean default false not null
);

create table if not exists silver.dim_product (
    product_key integer generated always as identity not null,
    platform text not null,
    platform_product_id text not null,
    brand_key text not null,
    product_name text not null,
    variant text,
    product_type text,
    pack_raw text,
    size_value numeric,
    size_unit text,
    pack_count integer default 1 not null,
    total_content numeric generated always as ((size_value * (pack_count)::numeric)) stored,
    category_key integer,
    listing_id integer,
    catalog_product_id integer,
    image_url text,
    product_url text,
    first_seen_at timestamp with time zone,
    last_seen_at timestamp with time zone,
    has_bonus_pack boolean generated always as ((pack_raw ~* '\d\s*(?:kg|gms?|g|ml|ltr|l)?\s*\+\s*\d'::text)) stored,
    product_name_std text generated always as (btrim(regexp_replace(product_name, '\s+'::text, ' '::text, 'g'::text))) stored
) with (autovacuum_vacuum_scale_factor=0.05, autovacuum_analyze_scale_factor=0.05);

create table if not exists silver.dim_store (
    store_key integer generated always as identity not null,
    platform text not null,
    store_external_id text not null,
    source_store_id integer not null,
    store_name text,
    city_slug text,
    latitude double precision,
    longitude double precision,
    first_seen_at timestamp with time zone,
    last_seen_at timestamp with time zone,
    "store_weight (weight per store, e.g. store sales)" numeric
);

create table if not exists silver.fact_product_reading (
    reading_key bigint generated always as identity not null,
    source_type text not null,
    source_table text not null,
    source_record_id bigint not null,
    product_key integer not null,
    store_key integer,
    planned_store_key integer,
    city_slug text,
    job_ref text,
    run_id integer,
    scrape_id integer,
    snapshot_id bigint,
    listing_id integer,
    observed_at timestamp with time zone not null,
    obs_date date generated always as (((observed_at AT TIME ZONE 'Asia/Kolkata'::text))::date) stored,
    stock_state_raw text,
    stock_status text not null,
    is_listed boolean not null,
    is_available boolean,
    inventory_units integer,
    inventory_is_capped boolean default false not null,
    selling_price numeric(12,2),
    mrp numeric(12,2),
    discount_amount numeric(12,2) generated always as (
CASE
    WHEN ((mrp > (0)::numeric) AND (selling_price IS NOT NULL)) THEN (mrp - selling_price)
    ELSE NULL::numeric
END) stored,
    discount_pct numeric(7,2) generated always as (
CASE
    WHEN ((mrp > (0)::numeric) AND (selling_price IS NOT NULL)) THEN round((((mrp - selling_price) / mrp) * (100)::numeric), 2)
    ELSE NULL::numeric
END) stored,
    search_position integer,
    organic_position integer,
    is_ad boolean,
    ad_type text,
    osa_eligible boolean not null,
    dq_status text not null,
    dq_flags text[] default '{}'::text[] not null,
    loaded_at timestamp with time zone default now() not null,
    etl_run_id bigint
);

create table if not exists silver.fact_shelf_position (
    shelf_pos_key bigint generated always as identity not null,
    source_record_id bigint not null,
    snapshot_id bigint not null,
    platform text not null,
    l1_id text not null,
    l2_id text not null,
    store_key integer,
    city_slug text,
    observed_at timestamp with time zone not null,
    obs_date date generated always as (((observed_at AT TIME ZONE 'Asia/Kolkata'::text))::date) stored,
    shelf_position integer not null,
    organic_position integer,
    is_ad boolean,
    ad_type text,
    brand_raw text,
    brand_key text not null,
    is_client_brand boolean default false not null,
    platform_product_id text,
    product_name text,
    pack_raw text,
    stock_status text not null,
    inventory_units integer,
    inventory_is_capped boolean default false not null,
    selling_price numeric,
    mrp numeric,
    discount_pct numeric generated always as (
CASE
    WHEN ((mrp > (0)::numeric) AND (selling_price IS NOT NULL)) THEN round((((mrp - selling_price) / mrp) * (100)::numeric), 2)
    ELSE NULL::numeric
END) stored,
    shelf_cards_seen integer,
    shelf_total_items integer,
    shelf_complete boolean,
    dq_status text not null,
    dq_flags text[] default '{}'::text[] not null,
    loaded_at timestamp with time zone default now() not null,
    etl_run_id bigint,
    product_key integer
) with (autovacuum_vacuum_scale_factor=0.02, autovacuum_analyze_scale_factor=0.02, autovacuum_vacuum_insert_scale_factor=0.05);

create table if not exists silver.fact_store_scan (
    snapshot_id bigint not null,
    scrape_id integer,
    scrape_query text,
    platform text not null,
    brand_key text not null,
    store_key integer,
    planned_store_key integer,
    city_slug text,
    scanned_at timestamp with time zone not null,
    scan_status text not null,
    pages_read integer,
    cards_seen integer,
    brand_cards_matched integer,
    is_complete boolean,
    stopped_early boolean,
    is_valid_denominator boolean not null,
    dq_flags text[] default '{}'::text[] not null,
    loaded_at timestamp with time zone default now() not null,
    etl_run_id bigint
);

create table if not exists silver.freshness_policy (
    source_type text not null,
    fresh_within_hours integer not null,
    description text
);

create table if not exists silver.match_review_queue (
    review_id bigint generated always as identity not null,
    product_key integer not null,
    suggested_sidnl_id text not null,
    score numeric not null,
    rule_ok boolean not null,
    rule_reason text,
    score_detail jsonb default '{}'::jsonb not null,
    status text default 'pending'::text not null,
    created_at timestamp with time zone default now() not null,
    decided_by text,
    decided_at timestamp with time zone
);

create table if not exists silver.pipeline_source (
    source_schema text not null,
    source_table text not null,
    id_column text default 'id'::text not null,
    last_seen_id bigint default 0 not null,
    registry_last_id bigint default 0 not null
);

create table if not exists silver.product_xref (
    product_key integer not null,
    sidnl_id text not null,
    match_status text not null,
    match_method text not null,
    score numeric,
    score_detail jsonb default '{}'::jsonb not null,
    matched_at timestamp with time zone default now() not null,
    reviewed_by text,
    reviewed_at timestamp with time zone
);

create table if not exists silver.ref_metric_support (
    metric_id integer generated always as identity not null,
    pdf_section integer not null,
    section_name text not null,
    metric text not null,
    formula text not null,
    support text not null,
    silver_source text,
    notes text
);

create table if not exists silver.ref_noise_word (
    word text not null,
    is_active boolean default true not null
);

create table if not exists silver.ref_variant_synonym (
    syn_key text not null,
    variant text not null,
    is_active boolean default true not null
);

create table if not exists silver.sidnl_config (
    key text not null,
    value_num numeric,
    value_text text,
    description text
);

alter table dash.cfg_sku add constraint cfg_sku_pkey PRIMARY KEY (platform, platform_product_id);

alter table dash.cfg_threshold add constraint cfg_threshold_pkey PRIMARY KEY (key);

alter table dash.dim_brand add constraint dim_brand_pkey PRIMARY KEY (brand_key);

alter table dash.dim_category add constraint dim_category_pkey PRIMARY KEY (platform, l1_id, l2_id);

alter table dash.dim_city add constraint dim_city_pkey PRIMARY KEY (city_slug);

alter table dash.dim_date add constraint dim_date_pkey PRIMARY KEY (date_key);

alter table dash.dim_platform add constraint dim_platform_pkey PRIMARY KEY (platform);

alter table dash.dim_product add constraint dim_product_pkey PRIMARY KEY (product_key);

alter table dash.dim_sidnl add constraint dim_sidnl_pkey PRIMARY KEY (sidnl_id);

alter table dash.dim_store add constraint dim_store_pkey PRIMARY KEY (store_key);

alter table dash.metric_catalog add constraint metric_catalog_owner_team_check CHECK ((owner_team = ANY (ARRAY['scraping'::text, 'client_data'::text, 'data_eng'::text, 'product'::text])));

alter table dash.metric_catalog add constraint metric_catalog_pkey PRIMARY KEY (metric_key);

alter table dash.metric_catalog add constraint metric_catalog_status_check CHECK ((status = ANY (ARRAY['computed'::text, 'proxy'::text, 'partial'::text, 'blocked'::text])));

alter table dash.overview add constraint overview_pkey PRIMARY KEY (obs_date, platform, city_slug, sidnl_id);

alter table dash.pricing add constraint pricing_pkey PRIMARY KEY (obs_date, platform, city_slug, sidnl_id);

alter table dash.refresh_state add constraint refresh_state_pkey PRIMARY KEY (key);

alter table dash.refresh_table_state add constraint refresh_table_state_last_status_check CHECK ((last_status = ANY (ARRAY['success'::text, 'failed'::text])));

alter table dash.refresh_table_state add constraint refresh_table_state_pkey PRIMARY KEY (table_name);

alter table dash.visibility add constraint visibility_pkey PRIMARY KEY (obs_date, platform, city_slug, search_type, search_term, sidnl_id);

alter table dash.visibility add constraint visibility_search_type_check CHECK ((search_type = ANY (ARRAY['category'::text, 'keyword'::text])));

alter table ops.cron_alert_log add constraint cron_alert_log_level_check CHECK ((level = ANY (ARRAY['alert'::text, 'recovered'::text])));

alter table ops.cron_alert_log add constraint cron_alert_log_pkey PRIMARY KEY (alert_id);

alter table ops.dead_letter add constraint dead_letter_pkey PRIMARY KEY (dl_id);

alter table ops.dead_letter add constraint dead_letter_source_table_bronze_id_key UNIQUE (source_table, bronze_id);

alter table ops.dead_letter add constraint dead_letter_status_check CHECK ((status = ANY (ARRAY['open'::text, 'retrying'::text, 'resolved'::text, 'ignored'::text])));

alter table ops.dq_result add constraint dq_result_pkey PRIMARY KEY (dq_id);

alter table ops.dq_result add constraint dq_result_severity_check CHECK ((severity = ANY (ARRAY['blocking'::text, 'rejected'::text, 'warning'::text, 'accepted'::text])));

alter table ops.etl_run add constraint etl_run_pkey PRIMARY KEY (run_id);

alter table ops.etl_run add constraint etl_run_status_check CHECK ((status = ANY (ARRAY['running'::text, 'success'::text, 'failed'::text])));

alter table ops.freshness_cursor add constraint freshness_cursor_pkey PRIMARY KEY (source_table);

alter table ops.freshness_event add constraint freshness_event_pkey PRIMARY KEY (event_id);

alter table ops.freshness_override add constraint freshness_override_pkey PRIMARY KEY (platform, source_type);

alter table ops.freshness_state add constraint freshness_state_pkey PRIMARY KEY (platform, source_type);

alter table ops.function_backup add constraint function_backup_pkey PRIMARY KEY (fn, tag);

alter table ops.pipeline_job add constraint pipeline_job_job_type_check CHECK ((job_type = ANY (ARRAY['regular'::text, 'daily'::text])));

alter table ops.pipeline_job add constraint pipeline_job_pkey PRIMARY KEY (job_id);

alter table ops.pipeline_job add constraint pipeline_job_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'retry_wait'::text, 'success'::text, 'blocked'::text, 'failed'::text])));

alter table ops.pipeline_run add constraint pipeline_run_pkey PRIMARY KEY (run_id);

alter table ops.pipeline_run add constraint pipeline_run_status_check CHECK ((status = ANY (ARRAY['running'::text, 'success'::text, 'partial'::text, 'blocked'::text])));

alter table ops.reconciliation_log add constraint reconciliation_log_pkey PRIMARY KEY (recon_id);

alter table ops.reconciliation_log add constraint reconciliation_log_status_check CHECK ((status = ANY (ARRAY['ok'::text, 'mismatch'::text, 'skipped'::text])));

alter table ops.storage_alert_log add constraint storage_alert_log_pkey PRIMARY KEY (alert_id);

alter table ops.storage_snapshot add constraint storage_snapshot_pkey PRIMARY KEY (snapshot_date, relation);

alter table ops.store_city_filled add constraint store_city_filled_pkey PRIMARY KEY (store_key);

alter table silver.brand_scope add constraint brand_scope_pkey PRIMARY KEY (brand_key);

alter table silver.brand_string_registry add constraint brand_string_registry_pkey PRIMARY KEY (raw_brand);

alter table silver.canonical_product add constraint canonical_product_check CHECK ((is_active OR (merged_into IS NOT NULL)));

alter table silver.canonical_product add constraint canonical_product_pkey PRIMARY KEY (sidnl_id);

alter table silver.canonical_product add constraint canonical_product_sidnl_id_check CHECK ((sidnl_id ~ '^SI[0-9]{3,}$'::text));

alter table silver.category_scope add constraint category_scope_pkey PRIMARY KEY (platform, l1_id, l2_id);

alter table silver.dim_brand add constraint dim_brand_pkey PRIMARY KEY (brand_key);

alter table silver.dim_category add constraint dim_category_pkey PRIMARY KEY (category_key);

alter table silver.dim_category add constraint dim_category_platform_l1_id_l1_name_l2_id_l2_name_l3_id_l3__key UNIQUE NULLS NOT DISTINCT (platform, l1_id, l1_name, l2_id, l2_name, l3_id, l3_name);

alter table silver.dim_city add constraint dim_city_pkey PRIMARY KEY (city_slug);

alter table silver.dim_platform add constraint dim_platform_pkey PRIMARY KEY (platform);

alter table silver.dim_product add constraint dim_product_pkey PRIMARY KEY (product_key);

alter table silver.dim_product add constraint dim_product_platform_platform_product_id_key UNIQUE (platform, platform_product_id);

alter table silver.dim_store add constraint dim_store_pkey PRIMARY KEY (store_key);

alter table silver.dim_store add constraint dim_store_platform_store_external_id_key UNIQUE (platform, store_external_id);

alter table silver.dim_store add constraint dim_store_source_store_id_key UNIQUE (source_store_id);

alter table silver.fact_product_reading add constraint fact_product_reading_dq_status_check CHECK ((dq_status = ANY (ARRAY['valid'::text, 'suspect'::text, 'invalid'::text])));

alter table silver.fact_product_reading add constraint fact_product_reading_pkey PRIMARY KEY (reading_key);

alter table silver.fact_product_reading add constraint fact_product_reading_source_type_check CHECK ((source_type = ANY (ARRAY['stock_check'::text, 'brand_search'::text, 'category_shelf'::text])));

alter table silver.fact_product_reading add constraint fact_product_reading_source_type_source_record_id_key UNIQUE (source_type, source_record_id);

alter table silver.fact_product_reading add constraint fact_product_reading_stock_status_check CHECK ((stock_status = ANY (ARRAY['in_stock'::text, 'out_of_stock'::text, 'not_listed'::text, 'unknown'::text])));

alter table silver.fact_shelf_position add constraint fact_shelf_position_dq_status_check CHECK ((dq_status = ANY (ARRAY['valid'::text, 'suspect'::text, 'invalid'::text])));

alter table silver.fact_shelf_position add constraint fact_shelf_position_pkey PRIMARY KEY (shelf_pos_key);

alter table silver.fact_shelf_position add constraint fact_shelf_position_source_record_id_key UNIQUE (source_record_id);

alter table silver.fact_shelf_position add constraint fact_shelf_position_stock_status_check CHECK ((stock_status = ANY (ARRAY['in_stock'::text, 'out_of_stock'::text, 'not_listed'::text, 'unknown'::text])));

alter table silver.fact_store_scan add constraint fact_store_scan_pkey PRIMARY KEY (snapshot_id);

alter table silver.freshness_policy add constraint freshness_policy_fresh_within_hours_check CHECK ((fresh_within_hours > 0));

alter table silver.freshness_policy add constraint freshness_policy_pkey PRIMARY KEY (source_type);

alter table silver.freshness_policy add constraint freshness_policy_source_type_check CHECK ((source_type = ANY (ARRAY['stock_check'::text, 'brand_search'::text, 'category_shelf'::text])));

alter table silver.match_review_queue add constraint match_review_queue_pkey PRIMARY KEY (review_id);

alter table silver.match_review_queue add constraint match_review_queue_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'rejected'::text])));

alter table silver.pipeline_source add constraint pipeline_source_pkey PRIMARY KEY (source_schema, source_table);

alter table silver.product_xref add constraint product_xref_match_status_check CHECK ((match_status = ANY (ARRAY['MAPPED'::text, 'NEW_MASTER'::text, 'PENDING_REVIEW'::text, 'MANUAL'::text])));

alter table silver.product_xref add constraint product_xref_pkey PRIMARY KEY (product_key);

alter table silver.ref_metric_support add constraint ref_metric_support_pdf_section_metric_key UNIQUE (pdf_section, metric);

alter table silver.ref_metric_support add constraint ref_metric_support_pkey PRIMARY KEY (metric_id);

alter table silver.ref_metric_support add constraint ref_metric_support_support_check CHECK ((support = ANY (ARRAY['direct'::text, 'derived'::text, 'proxy'::text, 'partial'::text, 'not_available'::text])));

alter table silver.ref_noise_word add constraint ref_noise_word_pkey PRIMARY KEY (word);

alter table silver.ref_variant_synonym add constraint ref_variant_synonym_pkey PRIMARY KEY (syn_key);

alter table silver.sidnl_config add constraint sidnl_config_pkey PRIMARY KEY (key);

alter table dash.cfg_sku add constraint cfg_sku_brand_key_fkey FOREIGN KEY (brand_key) REFERENCES silver.dim_brand(brand_key);

alter table dash.cfg_sku add constraint cfg_sku_platform_fkey FOREIGN KEY (platform) REFERENCES silver.dim_platform(platform);

alter table dash.dim_category add constraint dim_category_platform_fkey FOREIGN KEY (platform) REFERENCES dash.dim_platform(platform);

alter table dash.dim_product add constraint dim_product_brand_key_fkey FOREIGN KEY (brand_key) REFERENCES dash.dim_brand(brand_key);

alter table dash.dim_product add constraint dim_product_platform_fkey FOREIGN KEY (platform) REFERENCES dash.dim_platform(platform);

alter table dash.dim_store add constraint dim_store_city_slug_fkey FOREIGN KEY (city_slug) REFERENCES dash.dim_city(city_slug);

alter table dash.dim_store add constraint dim_store_platform_fkey FOREIGN KEY (platform) REFERENCES dash.dim_platform(platform);

alter table ops.freshness_override add constraint freshness_override_source_type_fkey FOREIGN KEY (source_type) REFERENCES silver.freshness_policy(source_type);

alter table ops.freshness_state add constraint freshness_state_source_type_fkey FOREIGN KEY (source_type) REFERENCES silver.freshness_policy(source_type);

alter table silver.canonical_product add constraint canonical_product_brand_key_fkey FOREIGN KEY (brand_key) REFERENCES silver.dim_brand(brand_key);

alter table silver.canonical_product add constraint canonical_product_merged_into_fkey FOREIGN KEY (merged_into) REFERENCES silver.canonical_product(sidnl_id) DEFERRABLE;

alter table silver.category_scope add constraint category_scope_platform_fkey FOREIGN KEY (platform) REFERENCES silver.dim_platform(platform);

alter table silver.dim_brand add constraint dim_brand_brand_key_fkey FOREIGN KEY (brand_key) REFERENCES silver.brand_scope(brand_key);

alter table silver.dim_category add constraint dim_category_platform_fkey FOREIGN KEY (platform) REFERENCES silver.dim_platform(platform);

alter table silver.dim_product add constraint dim_product_brand_key_fkey FOREIGN KEY (brand_key) REFERENCES silver.dim_brand(brand_key);

alter table silver.dim_product add constraint dim_product_category_key_fkey FOREIGN KEY (category_key) REFERENCES silver.dim_category(category_key);

alter table silver.dim_product add constraint dim_product_platform_fkey FOREIGN KEY (platform) REFERENCES silver.dim_platform(platform);

alter table silver.dim_store add constraint dim_store_city_slug_fkey FOREIGN KEY (city_slug) REFERENCES silver.dim_city(city_slug);

alter table silver.dim_store add constraint dim_store_platform_fkey FOREIGN KEY (platform) REFERENCES silver.dim_platform(platform);

alter table silver.fact_product_reading add constraint fact_product_reading_city_slug_fkey FOREIGN KEY (city_slug) REFERENCES silver.dim_city(city_slug);

alter table silver.fact_product_reading add constraint fact_product_reading_etl_run_id_fkey FOREIGN KEY (etl_run_id) REFERENCES ops.etl_run(run_id);

alter table silver.fact_product_reading add constraint fact_product_reading_planned_store_key_fkey FOREIGN KEY (planned_store_key) REFERENCES silver.dim_store(store_key);

alter table silver.fact_product_reading add constraint fact_product_reading_product_key_fkey FOREIGN KEY (product_key) REFERENCES silver.dim_product(product_key);

alter table silver.fact_product_reading add constraint fact_product_reading_source_type_policy_fkey FOREIGN KEY (source_type) REFERENCES silver.freshness_policy(source_type);

alter table silver.fact_product_reading add constraint fact_product_reading_store_key_fkey FOREIGN KEY (store_key) REFERENCES silver.dim_store(store_key);

alter table silver.fact_shelf_position add constraint fact_shelf_position_brand_key_fkey FOREIGN KEY (brand_key) REFERENCES silver.dim_brand(brand_key) DEFERRABLE INITIALLY DEFERRED;

alter table silver.fact_shelf_position add constraint fact_shelf_position_category_scope_fkey FOREIGN KEY (platform, l1_id, l2_id) REFERENCES silver.category_scope(platform, l1_id, l2_id);

alter table silver.fact_shelf_position add constraint fact_shelf_position_city_slug_fkey FOREIGN KEY (city_slug) REFERENCES silver.dim_city(city_slug);

alter table silver.fact_shelf_position add constraint fact_shelf_position_etl_run_id_fkey FOREIGN KEY (etl_run_id) REFERENCES ops.etl_run(run_id);

alter table silver.fact_shelf_position add constraint fact_shelf_position_platform_fkey FOREIGN KEY (platform) REFERENCES silver.dim_platform(platform);

alter table silver.fact_shelf_position add constraint fact_shelf_position_product_key_fkey FOREIGN KEY (product_key) REFERENCES silver.dim_product(product_key);

alter table silver.fact_shelf_position add constraint fact_shelf_position_store_key_fkey FOREIGN KEY (store_key) REFERENCES silver.dim_store(store_key);

alter table silver.fact_store_scan add constraint fact_store_scan_brand_key_fkey FOREIGN KEY (brand_key) REFERENCES silver.dim_brand(brand_key);

alter table silver.fact_store_scan add constraint fact_store_scan_city_slug_fkey FOREIGN KEY (city_slug) REFERENCES silver.dim_city(city_slug);

alter table silver.fact_store_scan add constraint fact_store_scan_etl_run_id_fkey FOREIGN KEY (etl_run_id) REFERENCES ops.etl_run(run_id);

alter table silver.fact_store_scan add constraint fact_store_scan_planned_store_key_fkey FOREIGN KEY (planned_store_key) REFERENCES silver.dim_store(store_key);

alter table silver.fact_store_scan add constraint fact_store_scan_platform_fkey FOREIGN KEY (platform) REFERENCES silver.dim_platform(platform);

alter table silver.fact_store_scan add constraint fact_store_scan_store_key_fkey FOREIGN KEY (store_key) REFERENCES silver.dim_store(store_key);

alter table silver.match_review_queue add constraint match_review_queue_product_key_fkey FOREIGN KEY (product_key) REFERENCES silver.dim_product(product_key) ON DELETE CASCADE;

alter table silver.match_review_queue add constraint match_review_queue_suggested_sidnl_id_fkey FOREIGN KEY (suggested_sidnl_id) REFERENCES silver.canonical_product(sidnl_id) DEFERRABLE;

alter table silver.product_xref add constraint product_xref_product_key_fkey FOREIGN KEY (product_key) REFERENCES silver.dim_product(product_key) ON DELETE CASCADE;

alter table silver.product_xref add constraint product_xref_sidnl_id_fkey FOREIGN KEY (sidnl_id) REFERENCES silver.canonical_product(sidnl_id) DEFERRABLE;

CREATE UNIQUE INDEX ads_key ON dash.ads USING btree (obs_date, platform, campaign_id, keyword, sidnl_id) NULLS NOT DISTINCT;

CREATE UNIQUE INDEX availability_key ON dash.availability USING btree (obs_date, platform, city_slug, sidnl_id, store_key) NULLS NOT DISTINCT;

CREATE INDEX availability_store ON dash.availability USING btree (store_key, obs_date) WHERE (store_key IS NOT NULL);

CREATE INDEX ix_gold_dim_product_sidnl ON dash.dim_product USING btree (sidnl_id);

CREATE INDEX ix_dim_sidnl_brand ON dash.dim_sidnl USING btree (brand_key);

CREATE UNIQUE INDEX supply_key ON dash.supply USING btree (platform, po_number, sidnl_id, invoice_id) NULLS NOT DISTINCT;

CREATE INDEX ix_dead_letter_open ON ops.dead_letter USING btree (bronze_id) WHERE (status = 'open'::text);

CREATE INDEX dq_result_run_idx ON ops.dq_result USING btree (run_id);

CREATE UNIQUE INDEX pipeline_job_daily_uq ON ops.pipeline_job USING btree (job_type, job_date) WHERE (job_type = 'daily'::text);

CREATE INDEX pipeline_job_open_idx ON ops.pipeline_job USING btree (status) WHERE (status = ANY (ARRAY['queued'::text, 'retry_wait'::text]));

CREATE INDEX ix_recon_run ON ops.reconciliation_log USING btree (run_at DESC);

CREATE INDEX ix_canon_brand_pack ON silver.canonical_product USING btree (brand_key, pack_count) WHERE is_active;

CREATE INDEX ix_canon_name_trgm ON silver.canonical_product USING gin (name_clean gin_trgm_ops);

CREATE INDEX ix_dim_product_brand ON silver.dim_product USING btree (brand_key);

CREATE INDEX ix_dim_product_category ON silver.dim_product USING btree (category_key);

CREATE INDEX ix_dim_store_city ON silver.dim_store USING btree (city_slug);

CREATE INDEX ix_reading_date_prod ON silver.fact_product_reading USING btree (obs_date, product_key);

CREATE INDEX ix_reading_null_city ON silver.fact_product_reading USING btree (store_key) WHERE (city_slug IS NULL);

CREATE INDEX ix_reading_prod_store_time ON silver.fact_product_reading USING btree (product_key, store_key, observed_at DESC);

CREATE INDEX ix_reading_snapshot ON silver.fact_product_reading USING btree (snapshot_id) WHERE (snapshot_id IS NOT NULL);

CREATE INDEX ix_reading_source_time ON silver.fact_product_reading USING btree (source_type, observed_at DESC);

CREATE INDEX ix_reading_store ON silver.fact_product_reading USING btree (store_key);

CREATE INDEX fact_shelf_position_cat_idx ON silver.fact_shelf_position USING btree (platform, l2_id, obs_date);

CREATE INDEX fact_shelf_position_store_idx ON silver.fact_shelf_position USING btree (store_key);

CREATE INDEX ix_fsp_etl_run ON silver.fact_shelf_position USING btree (etl_run_id);

CREATE INDEX ix_fsp_null_city ON silver.fact_shelf_position USING btree (store_key) WHERE (city_slug IS NULL);

CREATE INDEX ix_fsp_platform_pid ON silver.fact_shelf_position USING btree (platform, platform_product_id);

CREATE INDEX ix_fsp_product_key ON silver.fact_shelf_position USING btree (product_key) WHERE (product_key IS NOT NULL);

CREATE INDEX ix_scan_scrape ON silver.fact_store_scan USING btree (scrape_id);

CREATE INDEX ix_scan_store_time ON silver.fact_store_scan USING btree (store_key, scanned_at DESC);

CREATE INDEX ix_review_pending ON silver.match_review_queue USING btree (status) WHERE (status = 'pending'::text);

CREATE UNIQUE INDEX ux_review_pair ON silver.match_review_queue USING btree (product_key, suggested_sidnl_id);

CREATE INDEX ix_xref_sidnl ON silver.product_xref USING btree (sidnl_id);

alter sequence ops.cron_alert_log_alert_id_seq owned by ops.cron_alert_log.alert_id;

alter sequence ops.dq_result_dq_id_seq owned by ops.dq_result.dq_id;

alter sequence ops.pipeline_job_job_id_seq owned by ops.pipeline_job.job_id;

alter sequence ops.storage_alert_log_alert_id_seq owned by ops.storage_alert_log.alert_id;

alter table dash.ads enable row level security;

alter table dash.availability enable row level security;

alter table dash.cfg_sku enable row level security;

alter table dash.cfg_threshold enable row level security;

alter table dash.dim_brand enable row level security;

alter table dash.dim_category enable row level security;

alter table dash.dim_city enable row level security;

alter table dash.dim_date enable row level security;

alter table dash.dim_platform enable row level security;

alter table dash.dim_product enable row level security;

alter table dash.dim_sidnl enable row level security;

alter table dash.dim_store enable row level security;

alter table dash.metric_catalog enable row level security;

alter table dash.overview enable row level security;

alter table dash.pricing enable row level security;

alter table dash.refresh_state enable row level security;

alter table dash.refresh_table_state enable row level security;

alter table dash.supply enable row level security;

alter table dash.visibility enable row level security;

alter table ops.backup_silver_057 enable row level security;

alter table ops.cron_alert_log enable row level security;

alter table ops.dead_letter enable row level security;

alter table ops.dq_result enable row level security;

alter table ops.etl_run enable row level security;

alter table ops.freshness_cursor enable row level security;

alter table ops.freshness_event enable row level security;

alter table ops.freshness_override enable row level security;

alter table ops.freshness_state enable row level security;

alter table ops.function_backup enable row level security;

alter table ops.pipeline_job enable row level security;

alter table ops.pipeline_run enable row level security;

alter table ops.reconciliation_log enable row level security;

alter table ops.storage_alert_log enable row level security;

alter table ops.storage_snapshot enable row level security;

alter table ops.store_city_filled enable row level security;

comment on table dash.ads is 'Ads Insights + Keyword Search tabs: campaign x keyword x SKU per day. Sum KPIs within one report_level. Loaded by the retail-media feed.';

comment on table dash.availability is 'Availability tab. store_key NULL = SKU x city total; store_key set = one dark store (Dark Store Map). Never sum both row types together.';

comment on table dash.cfg_sku is 'Client-defined target SKU list (assortment coverage) and optional per-SKU price threshold. Empty until the client confirms its target list.';

comment on table dash.cfg_threshold is 'Business-rule thresholds. is_confirmed=false means a default that the product/business team has not signed off (PDF section 11).';

comment on table dash.dim_city is 'Cities plus the pseudo-city ALL used for all-city roll-ups.';

comment on table dash.dim_product is 'Portal-facing product dimension, synced from silver.dim_product by gold.sync_dims() at the start of every gold refresh.';

comment on table dash.metric_catalog is 'Every PDF metric: formula, where it lives in gold, what input data is missing and which team owns closing the gap. status: computed = formula fully evaluated; proxy = stand-in formula; partial = table built but inputs incomplete; blocked = cannot be computed from scraped data.';

comment on table dash.overview is 'Overview tab: GMV, Net Sales, Units Sold, ASP, Market Share, Contribution Margin per SKU x city x day. Loaded by the sales feed.';

comment on table dash.pricing is 'Pricing + Price Parity tabs: observed MRP/SP/discount per SKU x city x day, parity vs national, lowest marketplace and reference platform.';

comment on table dash.refresh_table_state is 'One row per dash table rewritten by silver.run_gold_pending(). last_refreshed_at moves only on success; failures set last_attempt_at/last_status/last_error.';

comment on table dash.supply is 'Purchase Orders, Invoices, EDI and RCA warehouse/PO tabs: one row per PO line (x invoice). Fill rate roll-ups = SUM(grn_units)/SUM(po_units). Loaded by the vendor-portal/ERP/EDI feed.';

comment on table dash.visibility is 'Visibility tab: rank, impressions and SOV per SKU per category shelf (l1>l2) or keyword. SOV of a brand = sum over its SKUs in the same market. Keyword rows have no SOV (brand-only results).';

comment on table ops.backup_silver_057 is 'Rollback data for silver_057 (dim_product.first_seen_at before the correction). Safe to drop once silver_057 is accepted.';

comment on table ops.dead_letter is 'silver_063: bronze rows that failed to load with a permanent error. open = excluded from loads and retried; resolved = loaded later; ignored = closed by hand.';

comment on table ops.etl_run is 'One row per silver.refresh_brand() call, with row counts in stats.';

comment on table ops.freshness_event is 'silver_062: every freshness status change (fresh/stale/never_seen/not_expected).';

comment on table ops.freshness_override is 'silver_062: optional per-platform threshold, or expected=false for a source a platform is not scraped for.';

comment on table ops.freshness_state is 'silver_062: latest bronze row time per platform x source (maintained by silver.refresh_freshness).';

comment on table ops.pipeline_run is 'One row per pipeline run that actually did work. Idle ticks are not logged.';

comment on column ops.pipeline_run.gold_status is 'GOLD outcome, logged separately: success | failed | skipped';

comment on column ops.pipeline_run.status is 'SILVER outcome only: success | partial (a step failed) | blocked (quality gate blocked a scope). Gold never changes it.';

comment on table ops.reconciliation_log is 'silver_061: one row per reconciliation check per run (bronze -> silver -> dash).';

comment on table ops.store_city_filled is 'silver_060: stores whose city came from their bronze scrape snapshots (public.stores had no city). One unanimous city per store.';

comment on table silver.brand_scope is 'Brands tracked by silver. One row per brand; drives silver.refresh_brand().';

comment on column silver.brand_scope.scope_source is 'client = brand we report on (enabled); category_shelf = competitor brand seen on a scoped category shelf (disabled, only anchors dim_brand / SI ids)';

comment on table silver.brand_string_registry is 'Every distinct raw brand string seen in bronze. Lets brand matching run on strings, not rows.';

comment on table silver.canonical_product is 'One row per real-world product (SI id). Retired ids keep merged_into so old SI ids still resolve.';

comment on table silver.category_scope is 'Category shelves loaded market-wide (every brand) by silver.refresh_category_market(). Seeded from client product categories; insert a row to track another category.';

comment on table silver.dim_brand is 'Tracked brands (from silver.brand_scope).';

comment on table silver.dim_category is 'Platform category hierarchy (L1 > L2 > L3) parsed from listing breadcrumbs / shelf categories.';

comment on table silver.dim_city is 'Cities covered by the scrapers (from public.cities).';

comment on table silver.dim_platform is 'Quick-commerce platforms. is_test = demo/seed data that must never reach metrics.';

comment on table silver.dim_product is 'One row per (platform, platform product id) of a tracked brand. Pack text is parsed to size/unit/count.';

comment on column silver.dim_product.has_bonus_pack is 'pack_raw is an "A + B" bonus pack; size_value x pack_count (= total_content) covers all parts';

comment on column silver.dim_product.product_name_std is 'product_name with whitespace collapsed; product_name keeps the raw value';

comment on table silver.dim_store is 'Dark stores as the platform identifies them. Includes every store scanned, so it is also the listing-% denominator universe.';

comment on table silver.fact_product_reading is 'One product reading at one dark store at one time. Source-agnostic. Metrics must filter dq_status=''valid''; OSA additionally osa_eligible.';

comment on column silver.fact_product_reading.inventory_units is 'Front-end (dark-store) inventory units as displayed by the platform. Back-end inventory is not available from scraping.';

comment on column silver.fact_product_reading.is_available is 'Availability as seen: in_stock=true, out_of_stock=false, not_listed/unknown=null. Brand-search cards only ever show listed items, so OSA uses stock checks only (osa_eligible).';

comment on column silver.fact_product_reading.store_key is 'The store whose inventory/price is displayed (the serving store for search cards).';

comment on table silver.fact_shelf_position is 'Every product card on a scoped category shelf, ALL brands (market-wide), one row per position per shelf read. shelf_cards_seen vs shelf_total_items shows how deep the scraper read; shelf_complete=false means only the top of the shelf was captured. brand_key = client brand_key when matched, else normalised brand text.';

comment on table silver.fact_store_scan is 'One brand-search scan of one dark store. is_valid_denominator = status ok AND store resolved; use it as the "eligible stores" base for listing %.';

comment on column silver.fact_store_scan.stopped_early is 'Scraper stopped paging before the end of the result list: a brand card absent from a stopped-early scan may be a false negative.';

comment on table silver.freshness_policy is 'Age threshold (hours) after which a reading is labelled stale, per source type.';

comment on table silver.match_review_queue is 'Possible same-product pairs awaiting a human. Approve = merge into the suggested SI id; reject = keep separate.';

comment on table silver.pipeline_source is 'Bronze tables watched for new rows; last_seen_id is the watermark of the last successful pipeline run.';

comment on table silver.product_xref is 'dim_product -> SI id, with how it was matched. PENDING_REVIEW = provisional own SI id plus a suggestion in match_review_queue.';

comment on table silver.ref_metric_support is 'PDF metric -> silver support level, source columns and caveats. Documentation as data.';

comment on table silver.ref_noise_word is 'Uninformative tokens dropped from names before lexical matching.';

comment on table silver.ref_variant_synonym is 'syn_key -> canonical token, applied to names and variants before comparison.';

comment on table silver.sidnl_config is 'Matcher weights/thresholds and pipeline settings. Edit rows to tune; no redeploy needed.';
