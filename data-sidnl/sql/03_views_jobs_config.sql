-- data-sidnl schema, part 3 of 3: views in dependency order, grants, configuration rows (no data rows), pg_cron jobs
-- GENERATED from the live Supabase database by `python sidnl.py export-schema`. Do not edit by hand.
-- Documentation and recovery baseline only: the objects already exist in production; never apply this file there.
-- Recovery on an empty database: apply 01, 02, 03 in order, then run `select silver.run_pipeline(true, 'rebuild')`
-- to rebuild silver from bronze, then `select silver.run_gold_pending()` to rebuild dash.

create or replace view silver.v_reading with (security_invoker=true) as
 SELECT f.reading_key,
    f.source_type,
    f.source_record_id,
    f.job_ref,
    f.observed_at,
    f.obs_date,
    p.platform,
    b.brand_key,
    b.brand_name,
    b.company_name,
    p.product_key,
    p.platform_product_id,
    p.product_name,
    p.variant,
    p.product_type,
    p.pack_raw,
    p.size_value,
    p.size_unit,
    p.pack_count,
    c.l1_id,
    c.l1_name AS l1_category,
    c.l2_id,
    c.l2_name AS l2_category,
    c.l3_id,
    c.l3_name AS l3_category,
    c.category_path,
    s.store_key,
    s.source_store_id,
    s.store_external_id,
    s.store_name,
    f.city_slug,
    ct.city_name,
    ct.state,
    s.latitude,
    s.longitude,
    f.stock_status,
    f.is_listed,
    f.is_available,
    f.inventory_units,
    f.inventory_is_capped,
    f.selling_price,
    f.mrp,
    f.discount_amount,
    f.discount_pct,
    f.search_position,
    f.organic_position,
    f.is_ad,
    f.ad_type,
    f.osa_eligible,
    f.dq_status,
    f.dq_flags,
    round((EXTRACT(epoch FROM (now() - f.observed_at)) / (3600)::numeric), 1) AS age_hours,
        CASE
            WHEN (f.observed_at >= (now() - make_interval(hours => fp.fresh_within_hours))) THEN 'fresh'::text
            ELSE 'stale'::text
        END AS freshness
   FROM ((((((silver.fact_product_reading f
     JOIN silver.dim_product p ON ((p.product_key = f.product_key)))
     JOIN silver.dim_brand b ON ((b.brand_key = p.brand_key)))
     JOIN silver.freshness_policy fp ON ((fp.source_type = f.source_type)))
     LEFT JOIN silver.dim_category c ON ((c.category_key = p.category_key)))
     LEFT JOIN silver.dim_store s ON ((s.store_key = f.store_key)))
     LEFT JOIN silver.dim_city ct ON ((ct.city_slug = f.city_slug)));

create or replace view silver.v_reading_current with (security_invoker=true) as
 SELECT DISTINCT ON (product_key, store_key) reading_key,
    source_type,
    source_record_id,
    job_ref,
    observed_at,
    obs_date,
    platform,
    brand_key,
    brand_name,
    company_name,
    product_key,
    platform_product_id,
    product_name,
    variant,
    product_type,
    pack_raw,
    size_value,
    size_unit,
    pack_count,
    l1_id,
    l1_category,
    l2_id,
    l2_category,
    l3_id,
    l3_category,
    category_path,
    store_key,
    source_store_id,
    store_external_id,
    store_name,
    city_slug,
    city_name,
    state,
    latitude,
    longitude,
    stock_status,
    is_listed,
    is_available,
    inventory_units,
    inventory_is_capped,
    selling_price,
    mrp,
    discount_amount,
    discount_pct,
    search_position,
    organic_position,
    is_ad,
    ad_type,
    osa_eligible,
    dq_status,
    dq_flags,
    age_hours,
    freshness
   FROM silver.v_reading r
  WHERE ((dq_status = 'valid'::text) AND (store_key IS NOT NULL))
  ORDER BY product_key, store_key, observed_at DESC, reading_key DESC;

create or replace view silver.v_data_freshness with (security_invoker=true) as
 SELECT r.platform,
    r.brand_key,
    r.source_type,
    count(*) AS readings,
    count(*) FILTER (WHERE (r.freshness = 'fresh'::text)) AS fresh_readings,
    count(*) FILTER (WHERE (r.freshness = 'stale'::text)) AS stale_readings,
    round(((100.0 * (count(*) FILTER (WHERE (r.freshness = 'fresh'::text)))::numeric) / (count(*))::numeric), 1) AS pct_fresh,
    min(r.observed_at) AS first_observed_at,
    max(r.observed_at) AS last_observed_at,
    round((EXTRACT(epoch FROM (now() - max(r.observed_at))) / (3600)::numeric), 1) AS hours_since_last_reading,
    fp.fresh_within_hours,
        CASE
            WHEN (max(r.observed_at) >= (now() - make_interval(hours => fp.fresh_within_hours))) THEN 'fresh'::text
            ELSE 'stale'::text
        END AS source_status
   FROM (silver.v_reading r
     JOIN silver.freshness_policy fp ON ((fp.source_type = r.source_type)))
  GROUP BY r.platform, r.brand_key, r.source_type, fp.fresh_within_hours;

create or replace view ops.v_dq_summary as
 SELECT p.platform,
    p.brand_key,
    f.source_type,
    f.dq_status,
    flag.f AS dq_flag,
    count(*) AS readings
   FROM ((silver.fact_product_reading f
     JOIN silver.dim_product p ON ((p.product_key = f.product_key)))
     CROSS JOIN LATERAL unnest(
        CASE
            WHEN (cardinality(f.dq_flags) = 0) THEN ARRAY['(none)'::text]
            ELSE f.dq_flags
        END) flag(f))
  GROUP BY p.platform, p.brand_key, f.source_type, f.dq_status, flag.f;

create or replace view silver.v_sku_listing with (security_invoker=true) as
 WITH latest_scan AS (
         SELECT DISTINCT ON (s.brand_key, s.store_key) s.brand_key,
            s.store_key,
            s.snapshot_id,
            s.platform,
            s.scanned_at,
            s.stopped_early,
            COALESCE(s.city_slug, '(unknown)'::text) AS city_slug
           FROM silver.fact_store_scan s
          WHERE s.is_valid_denominator
          ORDER BY s.brand_key, s.store_key, s.scanned_at DESC, s.snapshot_id DESC
        ), eligible AS (
         SELECT latest_scan.platform,
            latest_scan.brand_key,
            COALESCE(latest_scan.city_slug, 'ALL'::text) AS city_slug,
            count(*) AS eligible_stores,
            count(*) FILTER (WHERE latest_scan.stopped_early) AS eligible_stores_stopped_early,
            max(latest_scan.scanned_at) AS latest_scan_at
           FROM latest_scan
          GROUP BY latest_scan.platform, latest_scan.brand_key, ROLLUP(latest_scan.city_slug)
        ), listed AS (
         SELECT ls.platform,
            ls.brand_key,
            COALESCE(ls.city_slug, 'ALL'::text) AS city_slug,
            f.product_key,
            count(DISTINCT ls.store_key) AS listing_stores
           FROM (latest_scan ls
             JOIN silver.fact_product_reading f ON (((f.snapshot_id = ls.snapshot_id) AND (f.source_type = 'brand_search'::text) AND (f.dq_status = 'valid'::text) AND f.is_listed)))
          GROUP BY ls.platform, ls.brand_key, f.product_key, ROLLUP(ls.city_slug)
        )
 SELECT p.platform,
    p.brand_key,
    p.product_key,
    p.platform_product_id,
    p.product_name,
    e.city_slug,
    e.eligible_stores,
    COALESCE(l.listing_stores, (0)::bigint) AS listing_stores,
    round(((100.0 * (COALESCE(l.listing_stores, (0)::bigint))::numeric) / (NULLIF(e.eligible_stores, 0))::numeric), 2) AS listing_pct,
    e.eligible_stores_stopped_early,
    e.latest_scan_at
   FROM ((silver.dim_product p
     JOIN eligible e ON (((e.platform = p.platform) AND (e.brand_key = p.brand_key))))
     LEFT JOIN listed l ON (((l.product_key = p.product_key) AND (l.city_slug = e.city_slug))));

create or replace view silver.v_wide with (security_invoker=true) as
 SELECT f.reading_key AS id,
    p.platform,
        CASE f.source_type
            WHEN 'stock_check'::text THEN 'observation'::text
            ELSE 'shelf_position'::text
        END AS source_type,
    f.source_record_id,
    p.listing_id,
    p.catalog_product_id AS product_id,
    s.source_store_id AS store_id,
    f.run_id,
    f.scrape_id AS scrape_run_id,
    c.l1_id,
    c.l1_name AS l1_category,
    c.l2_id,
    c.l2_name AS l2_category,
    c.l3_id,
    c.l3_name AS l3_category,
    c.category_path,
    p.platform_product_id,
    p.platform_product_id AS sku_code,
    p.product_name,
    p.product_name AS sku_name,
    b.brand_name AS brand,
    p.variant,
    NULL::text AS product_description,
    p.product_url,
    p.image_url,
    p.pack_raw AS pack_size,
    p.size_unit AS pack_unit,
    p.size_value AS quantity,
    p.size_unit AS quantity_unit,
    f.mrp,
    f.selling_price AS sale_price,
    f.discount_amount,
    f.discount_pct AS discount_percentage,
    round((f.selling_price / NULLIF(p.total_content, (0)::numeric)), 4) AS price_per_unit,
    'INR'::text AS currency,
    f.inventory_units AS inventory,
    f.inventory_is_capped AS inventory_capped,
    f.inventory_units AS available_quantity,
    f.is_available AS availability,
    f.stock_status,
        CASE
            WHEN (f.inventory_units IS NULL) THEN NULL::text
            WHEN f.inventory_is_capped THEN 'capped'::text
            ELSE 'exact'::text
        END AS inventory_status,
    NULL::integer AS delivery_eta_minutes,
    f.search_position AS "position",
    f.organic_position,
    f.is_ad,
    f.ad_type,
    p.product_type,
    s.store_external_id,
    s.store_name,
    ct.city_name AS city,
    f.city_slug,
    ct.state,
    NULL::text AS pincode,
    s.latitude,
    s.longitude,
    f.observed_at,
    f.observed_at AS scraped_at,
    f.loaded_at AS transformed_at,
    NULL::text AS source_url,
    sc.scan_status AS scrape_status,
    NULL::text AS scrape_backend,
    NULL::text AS scrape_run_status,
    f.dq_status AS data_quality_status,
    to_jsonb(f.dq_flags) AS validation_errors,
    NULL::jsonb AS raw_details,
    jsonb_build_object('source_type', f.source_type, 'source_table', f.source_table, 'job_ref', f.job_ref, 'etl_run_id', f.etl_run_id) AS source_metadata,
    ARRAY[f.source_record_id] AS bronze_record_ids
   FROM ((((((silver.fact_product_reading f
     JOIN silver.dim_product p ON ((p.product_key = f.product_key)))
     JOIN silver.dim_brand b ON ((b.brand_key = p.brand_key)))
     LEFT JOIN silver.dim_category c ON ((c.category_key = p.category_key)))
     LEFT JOIN silver.dim_store s ON ((s.store_key = f.store_key)))
     LEFT JOIN silver.dim_city ct ON ((ct.city_slug = f.city_slug)))
     LEFT JOIN silver.fact_store_scan sc ON (((sc.snapshot_id = f.snapshot_id) AND (f.source_type = 'brand_search'::text))));

create or replace view silver.blinkit with (security_invoker=true) as
 SELECT id,
    platform,
    source_type,
    source_record_id,
    listing_id,
    product_id,
    store_id,
    run_id,
    scrape_run_id,
    l1_id,
    l1_category,
    l2_id,
    l2_category,
    l3_id,
    l3_category,
    category_path,
    platform_product_id,
    sku_code,
    product_name,
    sku_name,
    brand,
    variant,
    product_description,
    product_url,
    image_url,
    pack_size,
    pack_unit,
    quantity,
    quantity_unit,
    mrp,
    sale_price,
    discount_amount,
    discount_percentage,
    price_per_unit,
    currency,
    inventory,
    inventory_capped,
    available_quantity,
    availability,
    stock_status,
    inventory_status,
    delivery_eta_minutes,
    "position",
    organic_position,
    is_ad,
    ad_type,
    product_type,
    store_external_id,
    store_name,
    city,
    city_slug,
    state,
    pincode,
    latitude,
    longitude,
    observed_at,
    scraped_at,
    transformed_at,
    source_url,
    scrape_status,
    scrape_backend,
    scrape_run_status,
    data_quality_status,
    validation_errors,
    raw_details,
    source_metadata,
    bronze_record_ids
   FROM silver.v_wide
  WHERE (platform = 'blinkit'::text);

create or replace view silver.zepto with (security_invoker=true) as
 SELECT id,
    platform,
    source_type,
    source_record_id,
    listing_id,
    product_id,
    store_id,
    run_id,
    scrape_run_id,
    l1_id,
    l1_category,
    l2_id,
    l2_category,
    l3_id,
    l3_category,
    category_path,
    platform_product_id,
    sku_code,
    product_name,
    sku_name,
    brand,
    variant,
    product_description,
    product_url,
    image_url,
    pack_size,
    pack_unit,
    quantity,
    quantity_unit,
    mrp,
    sale_price,
    discount_amount,
    discount_percentage,
    price_per_unit,
    currency,
    inventory,
    inventory_capped,
    available_quantity,
    availability,
    stock_status,
    inventory_status,
    delivery_eta_minutes,
    "position",
    organic_position,
    is_ad,
    ad_type,
    product_type,
    store_external_id,
    store_name,
    city,
    city_slug,
    state,
    pincode,
    latitude,
    longitude,
    observed_at,
    scraped_at,
    transformed_at,
    source_url,
    scrape_status,
    scrape_backend,
    scrape_run_status,
    data_quality_status,
    validation_errors,
    raw_details,
    source_metadata,
    bronze_record_ids
   FROM silver.v_wide
  WHERE (platform = 'zepto'::text);

create or replace view silver.instamart with (security_invoker=true) as
 SELECT id,
    platform,
    source_type,
    source_record_id,
    listing_id,
    product_id,
    store_id,
    run_id,
    scrape_run_id,
    l1_id,
    l1_category,
    l2_id,
    l2_category,
    l3_id,
    l3_category,
    category_path,
    platform_product_id,
    sku_code,
    product_name,
    sku_name,
    brand,
    variant,
    product_description,
    product_url,
    image_url,
    pack_size,
    pack_unit,
    quantity,
    quantity_unit,
    mrp,
    sale_price,
    discount_amount,
    discount_percentage,
    price_per_unit,
    currency,
    inventory,
    inventory_capped,
    available_quantity,
    availability,
    stock_status,
    inventory_status,
    delivery_eta_minutes,
    "position",
    organic_position,
    is_ad,
    ad_type,
    product_type,
    store_external_id,
    store_name,
    city,
    city_slug,
    state,
    pincode,
    latitude,
    longitude,
    observed_at,
    scraped_at,
    transformed_at,
    source_url,
    scrape_status,
    scrape_backend,
    scrape_run_status,
    data_quality_status,
    validation_errors,
    raw_details,
    source_metadata,
    bronze_record_ids
   FROM silver.v_wide
  WHERE (platform = 'instamart'::text);

create or replace view silver.jiomart with (security_invoker=true) as
 SELECT id,
    platform,
    source_type,
    source_record_id,
    listing_id,
    product_id,
    store_id,
    run_id,
    scrape_run_id,
    l1_id,
    l1_category,
    l2_id,
    l2_category,
    l3_id,
    l3_category,
    category_path,
    platform_product_id,
    sku_code,
    product_name,
    sku_name,
    brand,
    variant,
    product_description,
    product_url,
    image_url,
    pack_size,
    pack_unit,
    quantity,
    quantity_unit,
    mrp,
    sale_price,
    discount_amount,
    discount_percentage,
    price_per_unit,
    currency,
    inventory,
    inventory_capped,
    available_quantity,
    availability,
    stock_status,
    inventory_status,
    delivery_eta_minutes,
    "position",
    organic_position,
    is_ad,
    ad_type,
    product_type,
    store_external_id,
    store_name,
    city,
    city_slug,
    state,
    pincode,
    latitude,
    longitude,
    observed_at,
    scraped_at,
    transformed_at,
    source_url,
    scrape_status,
    scrape_backend,
    scrape_run_status,
    data_quality_status,
    validation_errors,
    raw_details,
    source_metadata,
    bronze_record_ids
   FROM silver.v_wide
  WHERE (platform = 'jiomart'::text);

create or replace view dash.v_valid_reading with (security_invoker=true) as
 SELECT r.reading_key,
    r.source_type,
    r.source_record_id,
    r.job_ref,
    r.observed_at,
    r.obs_date,
    r.platform,
    r.brand_key,
    r.brand_name,
    r.company_name,
    r.product_key,
    r.platform_product_id,
    r.product_name,
    r.variant,
    r.product_type,
    r.pack_raw,
    r.size_value,
    r.size_unit,
    r.pack_count,
    r.l1_id,
    r.l1_category,
    r.l2_id,
    r.l2_category,
    r.l3_id,
    r.l3_category,
    r.category_path,
    r.store_key,
    r.source_store_id,
    r.store_external_id,
    r.store_name,
    r.city_slug,
    r.city_name,
    r.state,
    r.latitude,
    r.longitude,
    r.stock_status,
    r.is_listed,
    r.is_available,
    r.inventory_units,
    r.inventory_is_capped,
    r.selling_price,
    r.mrp,
    r.discount_amount,
    r.discount_pct,
    r.search_position,
    r.organic_position,
    r.is_ad,
    r.ad_type,
    r.osa_eligible,
    r.dq_status,
    r.dq_flags,
    r.age_hours,
    r.freshness
   FROM (silver.v_reading r
     JOIN silver.dim_platform dp ON (((dp.platform = r.platform) AND (NOT dp.is_test))))
  WHERE (r.dq_status = 'valid'::text);

create or replace view silver.v_shelf_position with (security_invoker=true) as
 SELECT f.shelf_pos_key,
    f.source_record_id,
    f.snapshot_id,
    f.platform,
    f.l1_id,
    f.l2_id,
    f.store_key,
    f.city_slug,
    f.observed_at,
    f.obs_date,
    f.shelf_position,
    f.organic_position,
    f.is_ad,
    f.ad_type,
    f.brand_raw,
    f.brand_key,
    f.is_client_brand,
    f.platform_product_id,
    f.product_name,
    f.pack_raw,
    f.stock_status,
    f.inventory_units,
    f.inventory_is_capped,
    f.selling_price,
    f.mrp,
    f.discount_pct,
    f.shelf_cards_seen,
    f.shelf_total_items,
    f.shelf_complete,
    f.dq_status,
    f.dq_flags,
    f.loaded_at,
    f.etl_run_id,
    cs.l1_name,
    cs.l2_name,
    ((cs.l1_name || ' > '::text) || cs.l2_name) AS category_path,
    ds.store_name,
    ct.city_name,
    f.product_key
   FROM (((silver.fact_shelf_position f
     JOIN silver.category_scope cs ON (((cs.platform = f.platform) AND (cs.l1_id = f.l1_id) AND (cs.l2_id = f.l2_id))))
     LEFT JOIN silver.dim_store ds ON ((ds.store_key = f.store_key)))
     LEFT JOIN silver.dim_city ct ON ((ct.city_slug = f.city_slug)));

create or replace view silver.v_sidnl_product with (security_invoker=true) as
 WITH mem AS (
         SELECT c_1.sidnl_id,
            d.platform,
            d.platform_product_id,
            d.product_key,
            d.first_seen_at,
            d.last_seen_at,
            x.match_status
           FROM ((silver.canonical_product c_1
             JOIN silver.product_xref x ON ((x.sidnl_id = c_1.sidnl_id)))
             JOIN silver.dim_product d ON ((d.product_key = x.product_key)))
          WHERE c_1.is_active
        ), per AS (
         SELECT mem.sidnl_id,
            mem.platform,
            min(mem.platform_product_id) AS primary_id,
            to_jsonb(array_agg(mem.platform_product_id ORDER BY mem.platform_product_id)) AS all_ids
           FROM mem
          GROUP BY mem.sidnl_id, mem.platform
        ), pj AS (
         SELECT per.sidnl_id,
            jsonb_object_agg(per.platform, per.primary_id) AS platform_ids,
            jsonb_object_agg(per.platform, per.all_ids) AS platform_id_aliases
           FROM per
          GROUP BY per.sidnl_id
        ), agg AS (
         SELECT mem.sidnl_id,
            count(*) AS products,
            count(DISTINCT mem.platform) AS platform_count,
            array_agg(mem.product_key ORDER BY mem.platform, mem.product_key) AS product_keys,
            bool_or((mem.match_status = 'PENDING_REVIEW'::text)) AS needs_review,
            min(mem.first_seen_at) AS first_seen_at,
            max(mem.last_seen_at) AS last_seen_at
           FROM mem
          GROUP BY mem.sidnl_id
        )
 SELECT c.sidnl_id,
    c.brand_key,
    c.canonical_name,
    c.variant,
    c.size_value,
    c.size_unit,
    c.pack_count,
    c.category_l1,
    c.category_l2,
    c.category_l3,
    a.products,
    a.platform_count,
    pj.platform_ids,
    a.product_keys,
    a.needs_review,
    a.first_seen_at,
    a.last_seen_at,
    pj.platform_id_aliases
   FROM ((silver.canonical_product c
     JOIN agg a ON ((a.sidnl_id = c.sidnl_id)))
     JOIN pj ON ((pj.sidnl_id = c.sidnl_id)))
  WHERE c.is_active;

create or replace view silver.v_reading_by_sidnl with (security_invoker=true) as
 SELECT x.sidnl_id,
    r.reading_key,
    r.source_type,
    r.source_record_id,
    r.job_ref,
    r.observed_at,
    r.obs_date,
    r.platform,
    r.brand_key,
    r.brand_name,
    r.company_name,
    r.product_key,
    r.platform_product_id,
    r.product_name,
    r.variant,
    r.product_type,
    r.pack_raw,
    r.size_value,
    r.size_unit,
    r.pack_count,
    r.l1_id,
    r.l1_category,
    r.l2_id,
    r.l2_category,
    r.l3_id,
    r.l3_category,
    r.category_path,
    r.store_key,
    r.source_store_id,
    r.store_external_id,
    r.store_name,
    r.city_slug,
    r.city_name,
    r.state,
    r.latitude,
    r.longitude,
    r.stock_status,
    r.is_listed,
    r.is_available,
    r.inventory_units,
    r.inventory_is_capped,
    r.selling_price,
    r.mrp,
    r.discount_amount,
    r.discount_pct,
    r.search_position,
    r.organic_position,
    r.is_ad,
    r.ad_type,
    r.osa_eligible,
    r.dq_status,
    r.dq_flags,
    r.age_hours,
    r.freshness
   FROM (silver.product_xref x
     JOIN silver.v_reading r ON ((r.product_key = x.product_key)));

create or replace view ops.v_pipeline_status with (security_invoker=true) as
 SELECT ( SELECT pipeline_run.started_at
           FROM ops.pipeline_run
          ORDER BY pipeline_run.run_id DESC
         LIMIT 1) AS last_run_at,
    ( SELECT pipeline_run.status
           FROM ops.pipeline_run
          ORDER BY pipeline_run.run_id DESC
         LIMIT 1) AS last_run_status,
    ( SELECT round(EXTRACT(epoch FROM (pipeline_run.finished_at - pipeline_run.started_at)), 1) AS round
           FROM ops.pipeline_run
          ORDER BY pipeline_run.run_id DESC
         LIMIT 1) AS last_run_seconds,
    ( SELECT count(*) AS count
           FROM silver.dim_product p
          WHERE (NOT (EXISTS ( SELECT 1
                   FROM silver.product_xref x
                  WHERE (x.product_key = p.product_key))))) AS products_without_si_id,
    ( SELECT count(*) AS count
           FROM silver.match_review_queue
          WHERE (match_review_queue.status = 'pending'::text)) AS reviews_pending,
    ( SELECT count(*) AS count
           FROM silver.canonical_product
          WHERE canonical_product.is_active) AS si_ids,
    ( SELECT count(*) AS count
           FROM silver.v_sidnl_product
          WHERE (v_sidnl_product.platform_count > 1)) AS si_ids_on_multiple_platforms,
    ( SELECT count(*) AS count
           FROM ops.pipeline_run
          WHERE ((pipeline_run.status = 'partial'::text) AND (pipeline_run.started_at > (now() - '24:00:00'::interval)))) AS failed_runs_24h;

create or replace view ops.v_quality_latest with (security_invoker=true) as
 SELECT check_name,
    ok,
    detail
   FROM silver.quality_checks() quality_checks(check_name, ok, detail);

create or replace view silver.v_match_health with (security_invoker=true) as
 SELECT match_status,
    match_method,
    count(*) AS products,
    round(avg(score), 3) AS avg_score,
    round(min(score), 3) AS min_score,
    count(DISTINCT sidnl_id) AS si_ids
   FROM silver.product_xref x
  GROUP BY match_status, match_method;

create or replace view silver.v_canonical_product_map with (security_invoker=true) as
 SELECT c.sidnl_id,
    COALESCE(b.brand_name, c.brand_key) AS brand,
    c.canonical_name AS product_name,
    c.variant,
    c.product_type,
    trim_scale(c.size_value) AS size_value,
    c.size_unit,
    c.pack_count,
    cat.l1_name AS category_l1,
    cat.l2_name AS category_l2,
    cat.l3_name AS category_l3,
    m.platforms,
    m.platform_count,
    m.platform_ids,
    m.listings AS platform_listings,
    m.image_url,
    m.first_seen_at,
    m.last_seen_at,
    m.needs_review
   FROM (((silver.canonical_product c
     LEFT JOIN silver.dim_brand b ON ((b.brand_key = c.brand_key)))
     LEFT JOIN LATERAL ( SELECT array_agg(DISTINCT d.platform ORDER BY d.platform) AS platforms,
            count(DISTINCT d.platform) AS platform_count,
            count(*) AS listings,
            ( SELECT jsonb_object_agg(z.platform, z.ids) AS jsonb_object_agg
                   FROM ( SELECT d2.platform,
                            to_jsonb(array_agg(d2.platform_product_id ORDER BY d2.platform_product_id)) AS ids
                           FROM (silver.product_xref x2
                             JOIN silver.dim_product d2 ON ((d2.product_key = x2.product_key)))
                          WHERE (x2.sidnl_id = c.sidnl_id)
                          GROUP BY d2.platform) z) AS platform_ids,
            (array_agg(d.image_url ORDER BY (d.image_url IS NULL), d.product_key))[1] AS image_url,
            min(d.first_seen_at) AS first_seen_at,
            max(d.last_seen_at) AS last_seen_at,
            bool_or((x.match_status = 'PENDING_REVIEW'::text)) AS needs_review
           FROM (silver.product_xref x
             JOIN silver.dim_product d ON ((d.product_key = x.product_key)))
          WHERE (x.sidnl_id = c.sidnl_id)) m ON (true))
     LEFT JOIN LATERAL ( SELECT dc.l1_name,
            dc.l2_name,
            dc.l3_name
           FROM ((silver.product_xref x
             JOIN silver.dim_product d ON ((d.product_key = x.product_key)))
             JOIN silver.dim_category dc ON ((dc.category_key = d.category_key)))
          WHERE (x.sidnl_id = c.sidnl_id)
          ORDER BY (dc.l3_name IS NOT NULL) DESC, (dc.l2_name IS NOT NULL) DESC, d.product_key
         LIMIT 1) cat ON (true))
  WHERE c.is_active;

create or replace view silver.v_canonical_brand_summary with (security_invoker=true) as
 SELECT brand,
    count(*) AS products,
    sum(platform_listings) AS platform_listings,
    count(*) FILTER (WHERE (platform_count > 1)) AS on_multiple_platforms,
    count(*) FILTER (WHERE (category_l3 IS NOT NULL)) AS with_l3_category,
    count(*) FILTER (WHERE needs_review) AS needing_review
   FROM silver.v_canonical_product_map
  GROUP BY brand;

create or replace view ops.v_storage_monitor with (security_invoker=true) as
 SELECT (((n.nspname)::text || '.'::text) || (c.relname)::text) AS relation,
    pg_size_pretty(pg_total_relation_size((c.oid)::regclass)) AS total_size,
    pg_total_relation_size((c.oid)::regclass) AS total_bytes,
    pg_size_pretty(pg_relation_size((c.oid)::regclass)) AS table_size,
    pg_size_pretty(pg_indexes_size((c.oid)::regclass)) AS index_size,
    s.n_live_tup AS live_rows,
    s.n_dead_tup AS dead_rows,
    round(((100.0 * (s.n_dead_tup)::numeric) / (NULLIF((s.n_live_tup + s.n_dead_tup), 0))::numeric), 1) AS dead_pct,
    s.last_autovacuum,
    s.last_autoanalyze,
    pg_size_pretty(pg_database_size(current_database())) AS database_size
   FROM ((pg_class c
     JOIN pg_namespace n ON ((n.oid = c.relnamespace)))
     LEFT JOIN pg_stat_all_tables s ON ((s.relid = c.oid)))
  WHERE ((c.relkind = 'r'::"char") AND (n.nspname = ANY (ARRAY['silver'::name, 'public'::name])) AND (pg_total_relation_size((c.oid)::regclass) > ((5 * 1024) * 1024)))
  ORDER BY (pg_total_relation_size((c.oid)::regclass)) DESC;

create or replace view ops.v_dq_latest with (security_invoker=true) as
 SELECT run_id,
    checked_at,
    check_name,
    severity,
    scope,
    violations,
    total,
    ok,
    blocks,
    detail
   FROM ops.dq_result d
  WHERE (run_id = ( SELECT max(dq_result.run_id) AS max
           FROM ops.dq_result));

create or replace view ops.v_job_history with (security_invoker=true) as
 SELECT job_id,
    job_type,
    job_date,
    trigger,
    status,
    attempt,
    max_attempts,
    requested_at,
    next_attempt_at,
    finished_at,
    run_id,
    failed_stage,
    error_class,
    last_error,
    lock_waits,
    note
   FROM ops.pipeline_job j
  ORDER BY job_id DESC;

create or replace view ops.v_silver_health with (security_invoker=true) as
 WITH lr AS (
         SELECT pipeline_run.run_id,
            pipeline_run.started_at,
            pipeline_run.finished_at,
            pipeline_run.trigger,
            pipeline_run.status,
            pipeline_run.new_data,
            pipeline_run.steps,
            pipeline_run.gold_status,
            pipeline_run.gold_error,
            pipeline_run.gold_seconds,
            pipeline_run.dq,
            pipeline_run.watermarks_advanced,
            pipeline_run.job_id,
            pipeline_run.attempt,
            pipeline_run.shelf_rows_inserted,
            pipeline_run.shelf_rows_updated,
            pipeline_run.rows_rejected,
            pipeline_run.failed_stage,
            pipeline_run.error_message,
            pipeline_run.gold_attempts,
            pipeline_run.gold_next_at
           FROM ops.pipeline_run
          WHERE (pipeline_run.status <> 'running'::text)
          ORDER BY pipeline_run.run_id DESC
         LIMIT 1
        ), ls AS (
         SELECT max(pipeline_run.started_at) AS t
           FROM ops.pipeline_run
          WHERE (pipeline_run.status = 'success'::text)
        ), lf AS (
         SELECT max(pipeline_run.started_at) AS t
           FROM ops.pipeline_run
          WHERE (pipeline_run.status = ANY (ARRAY['partial'::text, 'blocked'::text]))
        ), le AS (
         SELECT pipeline_run.failed_stage,
            pipeline_run.error_message,
            pipeline_run.started_at
           FROM ops.pipeline_run
          WHERE (pipeline_run.failed_stage IS NOT NULL)
          ORDER BY pipeline_run.run_id DESC
         LIMIT 1
        ), gd AS (
         SELECT max(pipeline_run.started_at) FILTER (WHERE (pipeline_run.gold_status = 'success'::text)) AS last_gold_ok
           FROM ops.pipeline_run
        ), gl AS (
         SELECT pipeline_run.gold_status,
            pipeline_run.gold_error,
            pipeline_run.gold_attempts
           FROM ops.pipeline_run
          WHERE (pipeline_run.gold_status IS NOT NULL)
          ORDER BY pipeline_run.run_id DESC
         LIMIT 1
        )
 SELECT
        CASE
            WHEN ((EXISTS ( SELECT 1
               FROM ops.pipeline_job
              WHERE ((pipeline_job.status = 'failed'::text) AND (pipeline_job.finished_at > (now() - '24:00:00'::interval))))) OR (( SELECT lr.status
               FROM lr) = 'partial'::text)) THEN 'degraded'::text
            WHEN (( SELECT lr.status
               FROM lr) = 'blocked'::text) THEN 'blocked'::text
            ELSE 'healthy'::text
        END AS silver_health,
    ( SELECT lr.started_at
           FROM lr) AS last_run_at,
    ( SELECT lr.status
           FROM lr) AS last_run_status,
    ( SELECT lr.trigger
           FROM lr) AS last_run_trigger,
    ( SELECT round(EXTRACT(epoch FROM (lr.finished_at - lr.started_at)), 1) AS round
           FROM lr) AS last_run_seconds,
    ( SELECT ls.t
           FROM ls) AS last_success_at,
    ( SELECT lf.t
           FROM lf) AS last_failure_at,
    ( SELECT lr.shelf_rows_inserted
           FROM lr) AS last_run_shelf_inserted,
    ( SELECT lr.shelf_rows_updated
           FROM lr) AS last_run_shelf_updated,
    ( SELECT lr.rows_rejected
           FROM lr) AS last_run_rows_rejected,
    ( SELECT count(*) AS count
           FROM ops.dq_result
          WHERE ((dq_result.run_id = ( SELECT max(dq_result_1.run_id) AS max
                   FROM ops.dq_result dq_result_1)) AND dq_result.blocks AND (dq_result.scope <> 'all'::text))) AS blocking_dq_violations,
    ( SELECT COALESCE(sum(dq_result.violations), (0)::numeric) AS "coalesce"
           FROM ops.dq_result
          WHERE ((dq_result.run_id = ( SELECT max(dq_result_1.run_id) AS max
                   FROM ops.dq_result dq_result_1)) AND (dq_result.severity = 'warning'::text) AND (dq_result.scope = 'all'::text))) AS dq_warning_rows,
    ( SELECT count(*) AS count
           FROM silver.fact_shelf_position
          WHERE ((fact_shelf_position.product_key IS NULL) AND (fact_shelf_position.platform_product_id IS NOT NULL))) AS unlinked_shelf_rows,
    ( SELECT count(*) AS count
           FROM silver.dim_product p
          WHERE (NOT (EXISTS ( SELECT 1
                   FROM silver.product_xref x
                  WHERE (x.product_key = p.product_key))))) AS products_without_si_id,
    ( SELECT count(*) AS count
           FROM silver.match_review_queue
          WHERE (match_review_queue.status = 'pending'::text)) AS reviews_pending,
    ( SELECT count(*) AS count
           FROM ops.pipeline_job
          WHERE (pipeline_job.status = 'retry_wait'::text)) AS jobs_waiting_retry,
    ( SELECT COALESCE(max(pipeline_job.attempt), 0) AS "coalesce"
           FROM ops.pipeline_job
          WHERE (pipeline_job.status = 'retry_wait'::text)) AS max_retry_count,
    ( SELECT count(*) AS count
           FROM ops.pipeline_job
          WHERE ((pipeline_job.status = 'failed'::text) AND (pipeline_job.finished_at > (now() - '24:00:00'::interval)))) AS jobs_failed_24h,
    ( SELECT count(*) AS count
           FROM ops.pipeline_job
          WHERE ((pipeline_job.status = 'blocked'::text) AND (pipeline_job.finished_at > (now() - '24:00:00'::interval)))) AS jobs_blocked_24h,
    ( SELECT le.failed_stage
           FROM le) AS last_error_stage,
    ( SELECT le.error_message
           FROM le) AS last_error_message,
    ( SELECT le.started_at
           FROM le) AS last_error_at,
    ( SELECT gl.gold_status
           FROM gl) AS gold_last_status,
    ( SELECT gl.gold_error
           FROM gl) AS gold_last_error,
    ( SELECT gd.last_gold_ok
           FROM gd) AS gold_last_success_at,
    ( SELECT max(fact_shelf_position.observed_at) AS max
           FROM silver.fact_shelf_position) AS newest_shelf_reading,
    ( SELECT COALESCE(sum(GREATEST((b.mx - ps.last_seen_id), (0)::bigint)), (0)::numeric) AS "coalesce"
           FROM (silver.pipeline_source ps
             CROSS JOIN LATERAL ( SELECT
                        CASE ps.source_table
                            WHEN 'shelf_positions'::text THEN ( SELECT max(shelf_positions.id) AS max
                               FROM shelf_positions)
                            WHEN 'shelf_snapshots'::text THEN (( SELECT max(shelf_snapshots.id) AS max
                               FROM shelf_snapshots))::bigint
                            WHEN 'search_cards'::text THEN ( SELECT max(search_cards.id) AS max
                               FROM search_cards)
                            WHEN 'search_snapshots'::text THEN ( SELECT max(search_snapshots.id) AS max
                               FROM search_snapshots)
                            WHEN 'observations'::text THEN ( SELECT max(observations.id) AS max
                               FROM observations)
                            WHEN 'platform_listings'::text THEN (( SELECT max(platform_listings.id) AS max
                               FROM platform_listings))::bigint
                            ELSE NULL::bigint
                        END AS mx) b)) AS bronze_rows_behind_watermark,
    (date_trunc('minute'::text, now()) + '00:01:00'::interval) AS next_regular_check_at,
        CASE
            WHEN (((now() AT TIME ZONE 'Asia/Kolkata'::text))::time without time zone < '00:05:00'::time without time zone) THEN ((((now() AT TIME ZONE 'Asia/Kolkata'::text))::date + '00:05:00'::time without time zone) AT TIME ZONE 'Asia/Kolkata'::text)
            ELSE (((((now() AT TIME ZONE 'Asia/Kolkata'::text))::date + 1) + '00:05:00'::time without time zone) AT TIME ZONE 'Asia/Kolkata'::text)
        END AS next_daily_run_at,
    ( SELECT pg_size_pretty(pg_database_size(current_database())) AS pg_size_pretty) AS database_size;

create or replace view ops.v_storage_projection as
 WITH days AS (
         SELECT (((now() AT TIME ZONE 'Asia/Kolkata'::text))::date - k.k) AS dy
           FROM generate_series(0, 13) k(k)
        ), per AS (
         SELECT ((sn.taken_at AT TIME ZONE 'Asia/Kolkata'::text))::date AS dy,
            count(*) AS n
           FROM (shelf_snapshots sn
             JOIN shelf_positions sp ON ((sp.snapshot_id = sn.id)))
          WHERE (sn.taken_at >= (now() - '15 days'::interval))
          GROUP BY (((sn.taken_at AT TIME ZONE 'Asia/Kolkata'::text))::date)
        ), rate AS (
         SELECT count(*) FILTER (WHERE (COALESCE(p.n, (0)::bigint) > 0)) AS active_days,
            (COALESCE(sum(p.n), (0)::numeric) / 14.0) AS avg_rows_per_day,
            COALESCE(max(p.n), (0)::bigint) AS peak_rows_day
           FROM (days d
             LEFT JOIN per p ON ((p.dy = d.dy)))
        ), cost AS (
         SELECT (((pg_total_relation_size('shelf_positions'::regclass))::numeric / (NULLIF(( SELECT count(*) AS count
                   FROM shelf_positions), 0))::numeric) + ((pg_total_relation_size('silver.fact_shelf_position'::regclass))::numeric / (NULLIF(( SELECT count(*) AS count
                   FROM silver.fact_shelf_position), 0))::numeric)) AS bytes_per_scraped_row
        )
 SELECT u.db_bytes,
    u.wal_bytes,
    u.used_bytes,
    u.plan_bytes,
    u.used_pct,
    u.level,
    r.active_days,
    r.avg_rows_per_day,
    r.peak_rows_day,
    round(c.bytes_per_scraped_row) AS bytes_per_scraped_row,
    round(((r.avg_rows_per_day * c.bytes_per_scraped_row) / (1048576)::numeric), 1) AS growth_mb_per_day_avg,
    round((((r.peak_rows_day)::numeric * c.bytes_per_scraped_row) / (1048576)::numeric), 1) AS growth_mb_per_day_peak,
    round((((u.plan_bytes - u.used_bytes))::numeric / NULLIF((r.avg_rows_per_day * c.bytes_per_scraped_row), (0)::numeric))) AS days_to_full_at_avg,
    round((((u.plan_bytes - u.used_bytes))::numeric / NULLIF(((r.peak_rows_day)::numeric * c.bytes_per_scraped_row), (0)::numeric))) AS days_to_full_at_peak
   FROM ((silver.storage_usage() u(db_bytes, wal_bytes, used_bytes, plan_bytes, used_pct, level)
     CROSS JOIN rate r)
     CROSS JOIN cost c);

create or replace view ops.v_cron_health with (security_invoker=true) as
 SELECT j.jobname,
    j.schedule,
    j.active,
    count(d.runid) FILTER (WHERE (d.start_time > (now() - '24:00:00'::interval))) AS runs_24h,
    count(d.runid) FILTER (WHERE ((d.start_time > (now() - '24:00:00'::interval)) AND (d.status = 'failed'::text))) AS failures_24h,
    max(d.start_time) FILTER (WHERE (d.status = 'succeeded'::text)) AS last_success_at,
    max(d.start_time) FILTER (WHERE (d.status = 'failed'::text)) AS last_failure_at,
    ( SELECT x.return_message
           FROM cron.job_run_details x
          WHERE ((x.jobid = j.jobid) AND (x.status = 'failed'::text))
          ORDER BY x.start_time DESC
         LIMIT 1) AS last_failure_message,
    ( SELECT count(*) AS count
           FROM cron.job_run_details x
          WHERE ((x.jobid = j.jobid) AND (x.status = 'failed'::text) AND (x.start_time > COALESCE(( SELECT max(y.start_time) AS max
                   FROM cron.job_run_details y
                  WHERE ((y.jobid = j.jobid) AND (y.status = 'succeeded'::text))), '-infinity'::timestamp with time zone)))) AS consecutive_failures
   FROM (cron.job j
     LEFT JOIN cron.job_run_details d ON (((d.jobid = j.jobid) AND (d.start_time > (now() - '7 days'::interval)))))
  WHERE (j.jobname ~~ 'sidnl-%'::text)
  GROUP BY j.jobid, j.jobname, j.schedule, j.active;

create or replace view silver.v_shelf_by_sidnl with (security_invoker=true) as
 SELECT x.sidnl_id,
    v.shelf_pos_key,
    v.source_record_id,
    v.snapshot_id,
    v.platform,
    v.l1_id,
    v.l2_id,
    v.store_key,
    v.city_slug,
    v.observed_at,
    v.obs_date,
    v.shelf_position,
    v.organic_position,
    v.is_ad,
    v.ad_type,
    v.brand_raw,
    v.brand_key,
    v.is_client_brand,
    v.platform_product_id,
    v.product_name,
    v.pack_raw,
    v.stock_status,
    v.inventory_units,
    v.inventory_is_capped,
    v.selling_price,
    v.mrp,
    v.discount_pct,
    v.shelf_cards_seen,
    v.shelf_total_items,
    v.shelf_complete,
    v.dq_status,
    v.dq_flags,
    v.loaded_at,
    v.etl_run_id,
    v.l1_name,
    v.l2_name,
    v.category_path,
    v.store_name,
    v.city_name,
    v.product_key
   FROM (silver.v_shelf_position v
     JOIN silver.product_xref x ON ((x.product_key = v.product_key)));

create or replace view silver.v_all_platforms as
 SELECT blinkit.id,
    blinkit.platform,
    blinkit.source_type,
    blinkit.source_record_id,
    blinkit.listing_id,
    blinkit.product_id,
    blinkit.store_id,
    blinkit.run_id,
    blinkit.scrape_run_id,
    blinkit.l1_id,
    blinkit.l1_category,
    blinkit.l2_id,
    blinkit.l2_category,
    blinkit.l3_id,
    blinkit.l3_category,
    blinkit.category_path,
    blinkit.platform_product_id,
    blinkit.sku_code,
    blinkit.product_name,
    blinkit.sku_name,
    blinkit.brand,
    blinkit.variant,
    blinkit.product_description,
    blinkit.product_url,
    blinkit.image_url,
    blinkit.pack_size,
    blinkit.pack_unit,
    blinkit.quantity,
    blinkit.quantity_unit,
    blinkit.mrp,
    blinkit.sale_price,
    blinkit.discount_amount,
    blinkit.discount_percentage,
    blinkit.price_per_unit,
    blinkit.currency,
    blinkit.inventory,
    blinkit.inventory_capped,
    blinkit.available_quantity,
    blinkit.availability,
    blinkit.stock_status,
    blinkit.inventory_status,
    blinkit.delivery_eta_minutes,
    blinkit."position",
    blinkit.organic_position,
    blinkit.is_ad,
    blinkit.ad_type,
    blinkit.product_type,
    blinkit.store_external_id,
    blinkit.store_name,
    blinkit.city,
    blinkit.city_slug,
    blinkit.state,
    blinkit.pincode,
    blinkit.latitude,
    blinkit.longitude,
    blinkit.observed_at,
    blinkit.scraped_at,
    blinkit.transformed_at,
    blinkit.source_url,
    blinkit.scrape_status,
    blinkit.scrape_backend,
    blinkit.scrape_run_status,
    blinkit.data_quality_status,
    blinkit.validation_errors,
    blinkit.raw_details,
    blinkit.source_metadata,
    blinkit.bronze_record_ids
   FROM silver.blinkit
  WHERE (blinkit.data_quality_status = 'valid'::text)
UNION ALL
 SELECT zepto.id,
    zepto.platform,
    zepto.source_type,
    zepto.source_record_id,
    zepto.listing_id,
    zepto.product_id,
    zepto.store_id,
    zepto.run_id,
    zepto.scrape_run_id,
    zepto.l1_id,
    zepto.l1_category,
    zepto.l2_id,
    zepto.l2_category,
    zepto.l3_id,
    zepto.l3_category,
    zepto.category_path,
    zepto.platform_product_id,
    zepto.sku_code,
    zepto.product_name,
    zepto.sku_name,
    zepto.brand,
    zepto.variant,
    zepto.product_description,
    zepto.product_url,
    zepto.image_url,
    zepto.pack_size,
    zepto.pack_unit,
    zepto.quantity,
    zepto.quantity_unit,
    zepto.mrp,
    zepto.sale_price,
    zepto.discount_amount,
    zepto.discount_percentage,
    zepto.price_per_unit,
    zepto.currency,
    zepto.inventory,
    zepto.inventory_capped,
    zepto.available_quantity,
    zepto.availability,
    zepto.stock_status,
    zepto.inventory_status,
    zepto.delivery_eta_minutes,
    zepto."position",
    zepto.organic_position,
    zepto.is_ad,
    zepto.ad_type,
    zepto.product_type,
    zepto.store_external_id,
    zepto.store_name,
    zepto.city,
    zepto.city_slug,
    zepto.state,
    zepto.pincode,
    zepto.latitude,
    zepto.longitude,
    zepto.observed_at,
    zepto.scraped_at,
    zepto.transformed_at,
    zepto.source_url,
    zepto.scrape_status,
    zepto.scrape_backend,
    zepto.scrape_run_status,
    zepto.data_quality_status,
    zepto.validation_errors,
    zepto.raw_details,
    zepto.source_metadata,
    zepto.bronze_record_ids
   FROM silver.zepto
  WHERE (zepto.data_quality_status = 'valid'::text)
UNION ALL
 SELECT instamart.id,
    instamart.platform,
    instamart.source_type,
    instamart.source_record_id,
    instamart.listing_id,
    instamart.product_id,
    instamart.store_id,
    instamart.run_id,
    instamart.scrape_run_id,
    instamart.l1_id,
    instamart.l1_category,
    instamart.l2_id,
    instamart.l2_category,
    instamart.l3_id,
    instamart.l3_category,
    instamart.category_path,
    instamart.platform_product_id,
    instamart.sku_code,
    instamart.product_name,
    instamart.sku_name,
    instamart.brand,
    instamart.variant,
    instamart.product_description,
    instamart.product_url,
    instamart.image_url,
    instamart.pack_size,
    instamart.pack_unit,
    instamart.quantity,
    instamart.quantity_unit,
    instamart.mrp,
    instamart.sale_price,
    instamart.discount_amount,
    instamart.discount_percentage,
    instamart.price_per_unit,
    instamart.currency,
    instamart.inventory,
    instamart.inventory_capped,
    instamart.available_quantity,
    instamart.availability,
    instamart.stock_status,
    instamart.inventory_status,
    instamart.delivery_eta_minutes,
    instamart."position",
    instamart.organic_position,
    instamart.is_ad,
    instamart.ad_type,
    instamart.product_type,
    instamart.store_external_id,
    instamart.store_name,
    instamart.city,
    instamart.city_slug,
    instamart.state,
    instamart.pincode,
    instamart.latitude,
    instamart.longitude,
    instamart.observed_at,
    instamart.scraped_at,
    instamart.transformed_at,
    instamart.source_url,
    instamart.scrape_status,
    instamart.scrape_backend,
    instamart.scrape_run_status,
    instamart.data_quality_status,
    instamart.validation_errors,
    instamart.raw_details,
    instamart.source_metadata,
    instamart.bronze_record_ids
   FROM silver.instamart
  WHERE (instamart.data_quality_status = 'valid'::text)
UNION ALL
 SELECT jiomart.id,
    jiomart.platform,
    jiomart.source_type,
    jiomart.source_record_id,
    jiomart.listing_id,
    jiomart.product_id,
    jiomart.store_id,
    jiomart.run_id,
    jiomart.scrape_run_id,
    jiomart.l1_id,
    jiomart.l1_category,
    jiomart.l2_id,
    jiomart.l2_category,
    jiomart.l3_id,
    jiomart.l3_category,
    jiomart.category_path,
    jiomart.platform_product_id,
    jiomart.sku_code,
    jiomart.product_name,
    jiomart.sku_name,
    jiomart.brand,
    jiomart.variant,
    jiomart.product_description,
    jiomart.product_url,
    jiomart.image_url,
    jiomart.pack_size,
    jiomart.pack_unit,
    jiomart.quantity,
    jiomart.quantity_unit,
    jiomart.mrp,
    jiomart.sale_price,
    jiomart.discount_amount,
    jiomart.discount_percentage,
    jiomart.price_per_unit,
    jiomart.currency,
    jiomart.inventory,
    jiomart.inventory_capped,
    jiomart.available_quantity,
    jiomart.availability,
    jiomart.stock_status,
    jiomart.inventory_status,
    jiomart.delivery_eta_minutes,
    jiomart."position",
    jiomart.organic_position,
    jiomart.is_ad,
    jiomart.ad_type,
    jiomart.product_type,
    jiomart.store_external_id,
    jiomart.store_name,
    jiomart.city,
    jiomart.city_slug,
    jiomart.state,
    jiomart.pincode,
    jiomart.latitude,
    jiomart.longitude,
    jiomart.observed_at,
    jiomart.scraped_at,
    jiomart.transformed_at,
    jiomart.source_url,
    jiomart.scrape_status,
    jiomart.scrape_backend,
    jiomart.scrape_run_status,
    jiomart.data_quality_status,
    jiomart.validation_errors,
    jiomart.raw_details,
    jiomart.source_metadata,
    jiomart.bronze_record_ids
   FROM silver.jiomart
  WHERE (jiomart.data_quality_status = 'valid'::text);

create or replace view silver.v_latest_observation as
 SELECT DISTINCT ON (platform, COALESCE((listing_id)::text, platform_product_id), store_id) id,
    platform,
    source_type,
    source_record_id,
    listing_id,
    product_id,
    store_id,
    run_id,
    scrape_run_id,
    l1_id,
    l1_category,
    l2_id,
    l2_category,
    l3_id,
    l3_category,
    category_path,
    platform_product_id,
    sku_code,
    product_name,
    sku_name,
    brand,
    variant,
    product_description,
    product_url,
    image_url,
    pack_size,
    pack_unit,
    quantity,
    quantity_unit,
    mrp,
    sale_price,
    discount_amount,
    discount_percentage,
    price_per_unit,
    currency,
    inventory,
    inventory_capped,
    available_quantity,
    availability,
    stock_status,
    inventory_status,
    delivery_eta_minutes,
    "position",
    organic_position,
    is_ad,
    ad_type,
    product_type,
    store_external_id,
    store_name,
    city,
    city_slug,
    state,
    pincode,
    latitude,
    longitude,
    observed_at,
    scraped_at,
    transformed_at,
    source_url,
    scrape_status,
    scrape_backend,
    scrape_run_status,
    data_quality_status,
    validation_errors,
    raw_details,
    source_metadata,
    bronze_record_ids
   FROM silver.v_all_platforms
  WHERE (source_type = 'observation'::text)
  ORDER BY platform, COALESCE((listing_id)::text, platform_product_id), store_id, observed_at DESC;

create or replace view silver.v_latest_shelf_position as
 SELECT DISTINCT ON (platform, COALESCE((listing_id)::text, platform_product_id), store_id) id,
    platform,
    source_type,
    source_record_id,
    listing_id,
    product_id,
    store_id,
    run_id,
    scrape_run_id,
    l1_id,
    l1_category,
    l2_id,
    l2_category,
    l3_id,
    l3_category,
    category_path,
    platform_product_id,
    sku_code,
    product_name,
    sku_name,
    brand,
    variant,
    product_description,
    product_url,
    image_url,
    pack_size,
    pack_unit,
    quantity,
    quantity_unit,
    mrp,
    sale_price,
    discount_amount,
    discount_percentage,
    price_per_unit,
    currency,
    inventory,
    inventory_capped,
    available_quantity,
    availability,
    stock_status,
    inventory_status,
    delivery_eta_minutes,
    "position",
    organic_position,
    is_ad,
    ad_type,
    product_type,
    store_external_id,
    store_name,
    city,
    city_slug,
    state,
    pincode,
    latitude,
    longitude,
    observed_at,
    scraped_at,
    transformed_at,
    source_url,
    scrape_status,
    scrape_backend,
    scrape_run_status,
    data_quality_status,
    validation_errors,
    raw_details,
    source_metadata,
    bronze_record_ids
   FROM silver.v_all_platforms
  WHERE (source_type = 'shelf_position'::text)
  ORDER BY platform, COALESCE((listing_id)::text, platform_product_id), store_id, scrape_run_id DESC NULLS LAST, observed_at DESC;

create or replace view dash.v_refresh_status with (security_invoker=true) as
 SELECT table_name,
    last_refreshed_at,
    round((EXTRACT(epoch FROM (now() - last_refreshed_at)) / (60)::numeric), 1) AS age_minutes,
    row_count,
    last_status,
    last_attempt_at,
    last_error,
    gold_attempts,
    next_retry_at,
    (last_status = 'failed'::text) AS refresh_failing,
    ((last_status = 'failed'::text) AND (next_retry_at IS NULL)) AS needs_attention,
    ((last_refreshed_at IS NULL) OR (EXISTS ( SELECT 1
           FROM ops.pipeline_run r
          WHERE ((r.status = 'success'::text) AND (((r.gold_status = 'pending'::text) AND (r.run_id > COALESCE(s.last_run_id, (0)::bigint))) OR ((r.gold_status = 'failed'::text) AND (r.run_id >= COALESCE(s.last_run_id, (0)::bigint)))) AND (COALESCE(r.finished_at, r.started_at) < (now() - make_interval(mins => (COALESCE(( SELECT c.value
                   FROM dash.cfg_threshold c
                  WHERE (c.key = 'gold_stale_minutes'::text)), (180)::numeric))::integer))))))) AS is_stale
   FROM dash.refresh_table_state s;

create or replace view dash.v_brand_scorecard with (security_invoker=true) as
 WITH vis AS (
         SELECT v.obs_date,
            v.platform,
            COALESCE(v.city_slug, 'ALL'::text) AS city_slug,
            s.brand_key,
            sum(v.impressions) AS brand_impressions,
            sum(v.organic_impressions) AS brand_organic_impressions,
            sum(v.paid_impressions) AS brand_paid_impressions,
            sum(v.top_of_search_impressions) AS brand_top_impressions,
            count(DISTINCT v.sidnl_id) AS skus_on_shelf,
            count(DISTINCT v.search_term) AS categories_present,
            min(v.best_search_rank) AS best_shelf_rank
           FROM (dash.visibility v
             JOIN dash.dim_sidnl s ON ((s.sidnl_id = v.sidnl_id)))
          WHERE (v.search_type = 'category'::text)
          GROUP BY GROUPING SETS ((v.obs_date, v.platform, v.city_slug, s.brand_key), (v.obs_date, v.platform, s.brand_key))
        ), mkt AS (
         SELECT v.obs_date,
            v.platform,
            COALESCE(v.city_slug, 'ALL'::text) AS city_slug,
            sum(v.impressions) AS market_impressions,
            sum(v.top_of_search_impressions) AS market_top_impressions,
            count(DISTINCT v.search_term) AS categories_tracked,
            count(DISTINCT s.brand_key) AS brands_on_shelf
           FROM (dash.visibility v
             JOIN dash.dim_sidnl s ON ((s.sidnl_id = v.sidnl_id)))
          WHERE (v.search_type = 'category'::text)
          GROUP BY GROUPING SETS ((v.obs_date, v.platform, v.city_slug), (v.obs_date, v.platform))
        ), av AS (
         SELECT a.obs_date,
            a.platform,
            COALESCE(a.city_slug, 'ALL'::text) AS city_slug,
            s.brand_key,
            count(DISTINCT a.sidnl_id) AS skus_tracked,
            sum(a.osa_available_obs) AS osa_available_obs,
            sum(a.osa_eligible_obs) AS osa_eligible_obs,
            sum(a.ds_listed_stores) AS listed_stores,
            sum(a.ds_eligible_stores) AS eligible_stores,
            count(DISTINCT a.sidnl_id) FILTER (WHERE (a.out_of_stock_stores > 0)) AS skus_with_stockouts,
            sum(a.out_of_stock_stores) AS out_of_stock_store_skus,
            sum(a.potential_sales_loss) AS potential_sales_loss
           FROM (dash.availability a
             JOIN dash.dim_sidnl s ON ((s.sidnl_id = a.sidnl_id)))
          WHERE (a.store_key IS NULL)
          GROUP BY GROUPING SETS ((a.obs_date, a.platform, a.city_slug, s.brand_key), (a.obs_date, a.platform, s.brand_key))
        ), pr AS (
         SELECT p.obs_date,
            p.platform,
            COALESCE(p.city_slug, 'ALL'::text) AS city_slug,
            s.brand_key,
            count(DISTINCT p.sidnl_id) AS skus_priced,
            sum(p.mrp) AS sum_mrp,
            sum(p.selling_price) AS sum_selling_price,
            count(*) FILTER (WHERE p.is_parity_break) AS parity_breaks,
            count(*) FILTER (WHERE (p.is_parity_break IS NOT NULL)) AS parity_checked
           FROM (dash.pricing p
             JOIN dash.dim_sidnl s ON ((s.sidnl_id = p.sidnl_id)))
          GROUP BY GROUPING SETS ((p.obs_date, p.platform, p.city_slug, s.brand_key), (p.obs_date, p.platform, s.brand_key))
        ), u AS (
         SELECT vis.obs_date,
            vis.platform,
            vis.city_slug,
            vis.brand_key,
            vis.brand_impressions,
            vis.brand_organic_impressions,
            vis.brand_paid_impressions,
            vis.brand_top_impressions,
            vis.skus_on_shelf,
            vis.categories_present,
            vis.best_shelf_rank,
            NULL::bigint AS skus_tracked,
            NULL::bigint AS osa_available_obs,
            NULL::bigint AS osa_eligible_obs,
            NULL::bigint AS listed_stores,
            NULL::bigint AS eligible_stores,
            NULL::bigint AS skus_with_stockouts,
            NULL::bigint AS out_of_stock_store_skus,
            NULL::numeric AS potential_sales_loss,
            NULL::bigint AS skus_priced,
            NULL::numeric AS sum_mrp,
            NULL::numeric AS sum_selling_price,
            NULL::bigint AS parity_breaks,
            NULL::bigint AS parity_checked
           FROM vis
        UNION ALL
         SELECT av.obs_date,
            av.platform,
            av.city_slug,
            av.brand_key,
            NULL::bigint,
            NULL::bigint,
            NULL::bigint,
            NULL::bigint,
            NULL::bigint,
            NULL::bigint,
            NULL::integer,
            av.skus_tracked,
            av.osa_available_obs,
            av.osa_eligible_obs,
            av.listed_stores,
            av.eligible_stores,
            av.skus_with_stockouts,
            av.out_of_stock_store_skus,
            av.potential_sales_loss,
            NULL::bigint,
            NULL::numeric,
            NULL::numeric,
            NULL::bigint,
            NULL::bigint
           FROM av
        UNION ALL
         SELECT pr.obs_date,
            pr.platform,
            pr.city_slug,
            pr.brand_key,
            NULL::bigint,
            NULL::bigint,
            NULL::bigint,
            NULL::bigint,
            NULL::bigint,
            NULL::bigint,
            NULL::integer,
            NULL::bigint,
            NULL::bigint,
            NULL::bigint,
            NULL::bigint,
            NULL::bigint,
            NULL::bigint,
            NULL::bigint,
            NULL::numeric,
            pr.skus_priced,
            pr.sum_mrp,
            pr.sum_selling_price,
            pr.parity_breaks,
            pr.parity_checked
           FROM pr
        ), g AS (
         SELECT u.obs_date,
            u.platform,
            u.city_slug,
            u.brand_key,
            max(u.brand_impressions) AS brand_impressions,
            max(u.brand_organic_impressions) AS brand_organic_impressions,
            max(u.brand_paid_impressions) AS brand_paid_impressions,
            max(u.brand_top_impressions) AS brand_top_impressions,
            max(u.skus_on_shelf) AS skus_on_shelf,
            max(u.categories_present) AS categories_present,
            max(u.best_shelf_rank) AS best_shelf_rank,
            max(u.skus_tracked) AS skus_tracked,
            max(u.osa_available_obs) AS osa_available_obs,
            max(u.osa_eligible_obs) AS osa_eligible_obs,
            max(u.listed_stores) AS listed_stores,
            max(u.eligible_stores) AS eligible_stores,
            max(u.skus_with_stockouts) AS skus_with_stockouts,
            max(u.out_of_stock_store_skus) AS out_of_stock_store_skus,
            max(u.potential_sales_loss) AS potential_sales_loss,
            max(u.skus_priced) AS skus_priced,
            max(u.sum_mrp) AS sum_mrp,
            max(u.sum_selling_price) AS sum_selling_price,
            max(u.parity_breaks) AS parity_breaks,
            max(u.parity_checked) AS parity_checked
           FROM u
          GROUP BY u.obs_date, u.platform, u.city_slug, u.brand_key
        )
 SELECT g.obs_date,
    g.platform,
    g.city_slug,
    g.brand_key,
    b.brand_name,
    b.company_name,
    b.is_client,
    m.categories_tracked,
    g.categories_present,
    g.skus_on_shelf,
    m.brands_on_shelf,
        CASE
            WHEN (m.market_impressions IS NOT NULL) THEN COALESCE(g.brand_impressions, (0)::bigint)
            ELSE NULL::bigint
        END AS shelf_impressions,
    m.market_impressions AS market_shelf_impressions,
    round(((100.0 * (COALESCE(g.brand_impressions, (0)::bigint))::numeric) / (NULLIF(m.market_impressions, 0))::numeric), 3) AS share_of_shelf_pct,
        CASE
            WHEN (m.market_top_impressions IS NOT NULL) THEN COALESCE(g.brand_top_impressions, (0)::bigint)
            ELSE NULL::bigint
        END AS top_of_shelf_impressions,
    m.market_top_impressions AS market_top_of_shelf_impressions,
    round(((100.0 * (COALESCE(g.brand_top_impressions, (0)::bigint))::numeric) / (NULLIF(m.market_top_impressions, 0))::numeric), 3) AS top_of_shelf_share_pct,
    g.brand_organic_impressions AS organic_shelf_impressions,
    g.brand_paid_impressions AS paid_shelf_impressions,
    g.best_shelf_rank,
        CASE
            WHEN (m.market_impressions IS NOT NULL) THEN rank() OVER (PARTITION BY g.obs_date, g.platform, g.city_slug ORDER BY COALESCE(g.brand_impressions, (0)::bigint) DESC)
            ELSE NULL::bigint
        END AS shelf_rank_among_brands,
    g.skus_tracked,
    g.osa_available_obs,
    g.osa_eligible_obs,
    round(((100.0 * (g.osa_available_obs)::numeric) / (NULLIF(g.osa_eligible_obs, 0))::numeric), 2) AS osa_pct,
    g.listed_stores,
    g.eligible_stores,
    round(((100.0 * (g.listed_stores)::numeric) / (NULLIF(g.eligible_stores, 0))::numeric), 2) AS listing_pct,
    g.skus_with_stockouts,
    g.out_of_stock_store_skus,
    g.potential_sales_loss,
    g.skus_priced,
    g.sum_mrp,
    g.sum_selling_price,
    round(((100.0 * (g.sum_mrp - g.sum_selling_price)) / NULLIF(g.sum_mrp, (0)::numeric)), 2) AS avg_discount_pct,
    g.parity_breaks,
    g.parity_checked
   FROM ((g
     LEFT JOIN mkt m ON (((m.obs_date = g.obs_date) AND (m.platform = g.platform) AND (m.city_slug = g.city_slug))))
     LEFT JOIN dash.dim_brand b ON ((b.brand_key = g.brand_key)));

create or replace view dash.v_brand_scorecard_latest with (security_invoker=true) as
 SELECT obs_date,
    platform,
    city_slug,
    brand_key,
    brand_name,
    company_name,
    is_client,
    categories_tracked,
    categories_present,
    skus_on_shelf,
    brands_on_shelf,
    shelf_impressions,
    market_shelf_impressions,
    share_of_shelf_pct,
    top_of_shelf_impressions,
    market_top_of_shelf_impressions,
    top_of_shelf_share_pct,
    organic_shelf_impressions,
    paid_shelf_impressions,
    best_shelf_rank,
    shelf_rank_among_brands,
    skus_tracked,
    osa_available_obs,
    osa_eligible_obs,
    osa_pct,
    listed_stores,
    eligible_stores,
    listing_pct,
    skus_with_stockouts,
    out_of_stock_store_skus,
    potential_sales_loss,
    skus_priced,
    sum_mrp,
    sum_selling_price,
    avg_discount_pct,
    parity_breaks,
    parity_checked
   FROM ( SELECT s.obs_date,
            s.platform,
            s.city_slug,
            s.brand_key,
            s.brand_name,
            s.company_name,
            s.is_client,
            s.categories_tracked,
            s.categories_present,
            s.skus_on_shelf,
            s.brands_on_shelf,
            s.shelf_impressions,
            s.market_shelf_impressions,
            s.share_of_shelf_pct,
            s.top_of_shelf_impressions,
            s.market_top_of_shelf_impressions,
            s.top_of_shelf_share_pct,
            s.organic_shelf_impressions,
            s.paid_shelf_impressions,
            s.best_shelf_rank,
            s.shelf_rank_among_brands,
            s.skus_tracked,
            s.osa_available_obs,
            s.osa_eligible_obs,
            s.osa_pct,
            s.listed_stores,
            s.eligible_stores,
            s.listing_pct,
            s.skus_with_stockouts,
            s.out_of_stock_store_skus,
            s.potential_sales_loss,
            s.skus_priced,
            s.sum_mrp,
            s.sum_selling_price,
            s.avg_discount_pct,
            s.parity_breaks,
            s.parity_checked,
            rank() OVER (PARTITION BY s.platform, s.brand_key, s.city_slug ORDER BY s.obs_date DESC) AS rk
           FROM dash.v_brand_scorecard s) z
  WHERE (rk = 1);

create or replace view ops.v_reconciliation_latest with (security_invoker=true) as
 SELECT DISTINCT ON (check_name) check_name,
    run_at,
    status,
    rows_checked,
    mismatches,
    detail
   FROM ops.reconciliation_log
  ORDER BY check_name, run_at DESC;

create or replace view dash.v_data_freshness with (security_invoker=true) as
 WITH plat AS (
         SELECT dim_platform.platform
           FROM silver.dim_platform
          WHERE (NOT dim_platform.is_test)
        UNION
         SELECT freshness_state.platform
           FROM ops.freshness_state
          WHERE (NOT (freshness_state.platform IN ( SELECT dim_platform.platform
                   FROM silver.dim_platform
                  WHERE dim_platform.is_test)))
        ), k AS (
         SELECT p.platform,
            fp.source_type,
            fp.fresh_within_hours
           FROM (plat p
             CROSS JOIN silver.freshness_policy fp)
        )
 SELECT k.platform,
    k.source_type,
    st.last_ok_at,
    st.last_attempt_at,
    st.last_failed_at,
    round((EXTRACT(epoch FROM (now() - st.last_ok_at)) / (3600)::numeric), 1) AS age_hours,
    COALESCE(o.fresh_within_hours, k.fresh_within_hours) AS max_age_hours,
        CASE
            WHEN (o.expected = false) THEN 'not_expected'::text
            WHEN (st.last_ok_at IS NULL) THEN 'never_seen'::text
            WHEN ((now() - st.last_ok_at) <= make_interval(hours => COALESCE(o.fresh_within_hours, k.fresh_within_hours))) THEN 'fresh'::text
            ELSE 'stale'::text
        END AS status,
    ((st.last_failed_at IS NOT NULL) AND ((st.last_ok_at IS NULL) OR (st.last_failed_at > st.last_ok_at))) AS latest_attempt_failed,
    st.status_since
   FROM ((k
     LEFT JOIN ops.freshness_state st ON (((st.platform = k.platform) AND (st.source_type = k.source_type))))
     LEFT JOIN ops.freshness_override o ON (((o.platform = k.platform) AND (o.source_type = k.source_type))));

create or replace view dash.v_platform_freshness with (security_invoker=true) as
 SELECT platform,
        CASE
            WHEN bool_and((status = ANY (ARRAY['never_seen'::text, 'not_expected'::text]))) THEN 'no_data'::text
            WHEN bool_or((status = 'stale'::text)) THEN 'stale'::text
            ELSE 'fresh'::text
        END AS status,
    max(last_ok_at) AS last_data_at,
    round((EXTRACT(epoch FROM (now() - max(last_ok_at))) / (3600)::numeric), 1) AS hours_since_last_data,
    COALESCE(array_agg(source_type ORDER BY source_type) FILTER (WHERE (status = 'stale'::text)), '{}'::text[]) AS stale_sources,
    COALESCE(array_agg(source_type ORDER BY source_type) FILTER (WHERE (status = 'fresh'::text)), '{}'::text[]) AS fresh_sources,
    COALESCE(array_agg(source_type ORDER BY source_type) FILTER (WHERE (status = 'never_seen'::text)), '{}'::text[]) AS never_seen_sources
   FROM dash.v_data_freshness
  GROUP BY platform;

create or replace view ops.v_dead_letter_summary with (security_invoker=true) as
 SELECT source_table,
    platform,
    l1_id,
    l2_id,
    status,
    count(*) AS rows,
    min(first_seen_at) AS oldest,
    max(retry_count) AS max_retries,
    (array_agg(reason ORDER BY last_seen_at DESC))[1] AS latest_reason
   FROM ops.dead_letter
  GROUP BY source_table, platform, l1_id, l2_id, status;

create or replace view ops.v_heartbeat with (security_invoker=true) as
 SELECT jobname,
    active,
    schedule,
    ( SELECT max(r.start_time) AS max
           FROM cron.job_run_details r
          WHERE (r.jobid = j.jobid)) AS last_start,
    ( SELECT r.status
           FROM cron.job_run_details r
          WHERE (r.jobid = j.jobid)
          ORDER BY r.start_time DESC
         LIMIT 1) AS last_status,
        CASE
            WHEN (jobname = 'sidnl-pipeline'::text) THEN (now() - make_interval(mins => (COALESCE(silver.cfg('heartbeat_pipeline_max_minutes'::text), (10)::numeric))::integer))
            WHEN (jobname = 'sidnl-gold'::text) THEN (now() - make_interval(mins => (COALESCE(silver.cfg('heartbeat_gold_max_minutes'::text), (10)::numeric))::integer))
            WHEN (schedule = ANY (ARRAY['35 18 * * *'::text, '5 19 * * *'::text, '20 19 * * *'::text, '40 19 * * *'::text])) THEN (now() - make_interval(hours => (COALESCE(silver.cfg('heartbeat_daily_max_hours'::text), (26)::numeric))::integer))
            WHEN (schedule = '* * * * *'::text) THEN (now() - '00:10:00'::interval)
            WHEN (schedule = '*/5 * * * *'::text) THEN (now() - '00:15:00'::interval)
            WHEN (schedule = '*/10 * * * *'::text) THEN (now() - '00:20:00'::interval)
            WHEN (schedule = '*/15 * * * *'::text) THEN (now() - '00:45:00'::interval)
            ELSE (now() - '25:00:00'::interval)
        END AS expected_by
   FROM cron.job j
  WHERE (jobname ~~ 'sidnl-%'::text);

create or replace view ops.v_alert_outbox_health with (security_invoker=true) as
 SELECT count(*) FILTER (WHERE (status = 'pending'::text)) AS pending,
    count(*) FILTER (WHERE (status = 'sending'::text)) AS sending,
    count(*) FILTER (WHERE (status = 'sent'::text)) AS sent,
    count(*) FILTER (WHERE (status = 'failed'::text)) AS failed,
    count(*) FILTER (WHERE (status = 'dead'::text)) AS dead,
    max((now() - created_at)) FILTER (WHERE (status = 'pending'::text)) AS oldest_pending_age
   FROM ops.alert_outbox;

comment on view dash.v_brand_scorecard is 'Brand scorecard per obs_date x platform x city (ALL = all cities) x brand, built only from dash.visibility/availability/pricing. Every % has its num/den; roll up as SUM(num)/SUM(den). NULL = not measured (category shelves: Blinkit; availability/pricing: client brands). shelf impressions are 0 only when that day''s shelves were tracked and the brand did not appear.';

comment on view dash.v_brand_scorecard_latest is 'dash.v_brand_scorecard: the latest obs_date that has any data for each platform x brand x city (obs_date is in the row, so a brand sees how recent its numbers are).';

comment on view dash.v_data_freshness is 'Bronze freshness per platform x source. status: fresh | stale (had data, nothing new within max_age_hours) | never_seen (no bronze row ever) | not_expected (ops.freshness_override). latest_attempt_failed = the scraper ran but its newest attempt failed.';

comment on view dash.v_platform_freshness is 'One row per platform for the "data stale" banner: no_data | stale (any source that had data is stale) | fresh.';

comment on view dash.v_refresh_status is 'App "last refreshed" badge: one row per dash table. is_stale = dash is BEHIND silver: a successful silver run newer than the one dash reflects has waited for gold longer than cfg_threshold.gold_stale_minutes (quiet scrapers do not make dash stale; see dash.v_platform_freshness for that). refresh_failing = latest attempt failed (old data still served). needs_attention = failed and no retry scheduled.';

comment on view dash.v_valid_reading is 'silver.v_reading limited to dq_status=valid and non-test platforms. Single entry point for all gold metrics.';

comment on view ops.v_alert_outbox_health is 'Alert outbox summary: pending > 0 = delivery behind; dead > 0 needs attention; all zero while delivery is off and no alerts exist.';

comment on view ops.v_cron_health is 'Per-cron-job health for sidnl-* jobs incl. failures that bypass silver.pipeline_job (statement timeouts).';

comment on view ops.v_dq_summary is 'How many readings carry each data-quality flag.';

comment on view ops.v_heartbeat is 'One row per sidnl-* cron job: schedule, last start/status, expected_by (the time it should have started after). Read by the heartbeat edge function through ops.heartbeat().';

comment on view ops.v_pipeline_status is 'One-row health check of the automatic pipeline and the canonical map.';

comment on view ops.v_reconciliation_latest is 'Latest result of each reconciliation check; the app can show "data verified at <run_at>".';

comment on view ops.v_silver_health is 'One-row Silver health: last success/failure, status, duration, rows, DQ, retries, last error, Gold status, next run.';

comment on view silver.blinkit is 'Compat: wide per-platform silver contract used by gold/RAG. Source = silver.v_wide.';

comment on view silver.instamart is 'Compat: wide per-platform silver contract used by gold/RAG. Source = silver.v_wide.';

comment on view silver.jiomart is 'Compat: wide per-platform silver contract used by gold/RAG. Source = silver.v_wide.';

comment on view silver.v_canonical_brand_summary is 'One row per brand: how many distinct products (SI ids) it has. A brand repeats in the product map once per SKU by design; use this view for brand-level counts.';

comment on view silver.v_canonical_product_map is 'Readable canonical product map: one row per real product (SI id) with display category names. A column is NULL only when the scrapers captured nothing for it.';

comment on view silver.v_data_freshness is 'Per platform x brand x source: reading counts split fresh/stale, and whether the source as a whole is still fresh.';

comment on view silver.v_match_health is 'How products were mapped: counts and scores per status/method. Watch PENDING_REVIEW and min_score.';

comment on view silver.v_reading is 'Denormalised readings with age_hours and freshness (fresh|stale per silver.freshness_policy). Includes all dq_status values - filter dq_status=''valid'' for metrics.';

comment on view silver.v_reading_by_sidnl is 'v_reading with the SI id attached: filter by sidnl_id to read one product across platforms.';

comment on view silver.v_reading_current is 'Latest valid reading per (product, store) across all sources: the current FE inventory / price / availability picture. Check freshness before trusting it.';

comment on view silver.v_shelf_by_sidnl is 'Category-shelf positions of a product, keyed by sidnl_id. Companion of v_reading_by_sidnl (store readings) and v_sidnl_product (one row per SI id).';

comment on view silver.v_sidnl_product is 'One row per SI id: canonical attributes plus the product id on every platform (platform_id_aliases = all ids).';

comment on view silver.v_sku_listing is 'Dark-store listing % per SKU x city (+ALL) from the latest valid scan of every store. listing_pct = listing_stores / eligible_stores x 100.';

comment on view silver.v_wide is 'Wide, gold/RAG-compatible projection of the star schema (see header of 006_compat_views.sql).';

comment on view silver.zepto is 'Compat: wide per-platform silver contract used by gold/RAG. Source = silver.v_wide.';

do $g$ begin
  if exists (select 1 from pg_roles where rolname = 'sidnl_chatbot_app') then
    grant SELECT on silver.blinkit to sidnl_chatbot_app;
    grant SELECT on silver.brand_scope to sidnl_chatbot_app;
    grant SELECT on silver.brand_string_registry to sidnl_chatbot_app;
    grant SELECT on silver.canonical_product to sidnl_chatbot_app;
    grant SELECT on silver.category_scope to sidnl_chatbot_app;
    grant SELECT on silver.dim_brand to sidnl_chatbot_app;
    grant SELECT on silver.dim_category to sidnl_chatbot_app;
    grant SELECT on silver.dim_city to sidnl_chatbot_app;
    grant SELECT on silver.dim_platform to sidnl_chatbot_app;
    grant SELECT on silver.dim_product to sidnl_chatbot_app;
    grant SELECT on silver.dim_store to sidnl_chatbot_app;
    grant SELECT on silver.fact_product_reading to sidnl_chatbot_app;
    grant SELECT on silver.fact_shelf_position to sidnl_chatbot_app;
    grant SELECT on silver.fact_store_scan to sidnl_chatbot_app;
    grant SELECT on silver.freshness_policy to sidnl_chatbot_app;
    grant SELECT on silver.instamart to sidnl_chatbot_app;
    grant SELECT on silver.jiomart to sidnl_chatbot_app;
    grant SELECT on silver.match_review_queue to sidnl_chatbot_app;
    grant SELECT on silver.pipeline_source to sidnl_chatbot_app;
    grant SELECT on silver.product_xref to sidnl_chatbot_app;
    grant SELECT on silver.ref_metric_support to sidnl_chatbot_app;
    grant SELECT on silver.ref_noise_word to sidnl_chatbot_app;
    grant SELECT on silver.ref_variant_synonym to sidnl_chatbot_app;
    grant SELECT on silver.sidnl_config to sidnl_chatbot_app;
    grant SELECT on silver.v_all_platforms to sidnl_chatbot_app;
    grant SELECT on silver.v_canonical_brand_summary to sidnl_chatbot_app;
    grant SELECT on silver.v_canonical_product_map to sidnl_chatbot_app;
    grant SELECT on silver.v_data_freshness to sidnl_chatbot_app;
    grant SELECT on silver.v_latest_observation to sidnl_chatbot_app;
    grant SELECT on silver.v_latest_shelf_position to sidnl_chatbot_app;
    grant SELECT on silver.v_match_health to sidnl_chatbot_app;
    grant SELECT on silver.v_reading to sidnl_chatbot_app;
    grant SELECT on silver.v_reading_by_sidnl to sidnl_chatbot_app;
    grant SELECT on silver.v_reading_current to sidnl_chatbot_app;
    grant SELECT on silver.v_shelf_by_sidnl to sidnl_chatbot_app;
    grant SELECT on silver.v_shelf_position to sidnl_chatbot_app;
    grant SELECT on silver.v_sidnl_product to sidnl_chatbot_app;
    grant SELECT on silver.v_sku_listing to sidnl_chatbot_app;
    grant SELECT on silver.v_wide to sidnl_chatbot_app;
    grant SELECT on silver.zepto to sidnl_chatbot_app;
  end if;
end $g$;

do $g$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant USAGE on schema ops to service_role;
  end if;
end $g$;

do $g$ begin
  if exists (select 1 from pg_roles where rolname = 'sidnl_chatbot_app') then
    grant USAGE on schema silver to sidnl_chatbot_app;
  end if;
end $g$;

insert into dash.cfg_threshold select * from json_populate_recordset(null::dash.cfg_threshold, '[{"key":"critical_osa_pct","value":50,"value_text":null,"description":"SKU x city is critical when latest OSA % is below this","is_confirmed":false,"updated_at":"2026-11-06T16:14:05.232042+00:00"}, 
 {"key":"gold_stale_minutes","value":180,"value_text":null,"description":"dash.v_refresh_status.is_stale: dash is behind silver - a successful silver run has been waiting for its gold refresh (pending or failed) longer than this many minutes","is_confirmed":false,"updated_at":"2026-11-10T09:48:54.499448+00:00"}, 
 {"key":"low_stock_fe_units","value":5,"value_text":null,"description":"Dark store counts as low stock when FE units <= this (dash.availability.low_stock_stores).","is_confirmed":false,"updated_at":"2026-11-09T10:11:47.537358+00:00"}, 
 {"key":"min_scan_depth_cards","value":20,"value_text":null,"description":"A stopped-early brand-search scan counts as shallow (listing % may undercount) only if it read fewer cards than this. Observed: stopped-early scans read 61-112 cards; brand cards rank within the first 5 positions.","is_confirmed":false,"updated_at":"2026-11-06T16:29:33.551481+00:00"}, 
 {"key":"parity_reference_platform","value":null,"value_text":"blinkit","description":"Reference platform for cross-platform price difference","is_confirmed":false,"updated_at":"2026-11-06T16:14:05.232042+00:00"}, 
 {"key":"parity_tolerance_pct","value":1.0,"value_text":null,"description":"Absolute price difference % above this is flagged as a parity break","is_confirmed":false,"updated_at":"2026-11-06T16:14:05.232042+00:00"}, 
 {"key":"priority_high_osa_pct","value":30,"value_text":null,"description":"Priority High when latest OSA % is below this","is_confirmed":false,"updated_at":"2026-11-06T16:14:05.232042+00:00"}, 
 {"key":"priority_medium_osa_pct","value":60,"value_text":null,"description":"Priority Medium when latest OSA % is below this (else Low)","is_confirmed":false,"updated_at":"2026-11-06T16:14:05.232042+00:00"}, 
 {"key":"top_of_search_n","value":10,"value_text":null,"description":"Positions <= N count as top of search","is_confirmed":false,"updated_at":"2026-11-06T16:14:05.232042+00:00"}]') on conflict do nothing;

insert into silver.brand_scope select * from json_populate_recordset(null::silver.brand_scope, '[{"brand_key":"amul","brand_name":"Amul","company_name":"Amul","raw_brand_aliases":["Amul"],"is_enabled":true,"created_at":"2026-11-07T18:33:00.090144+00:00","scope_source":"client"}, 
 {"brand_key":"mother dairy","brand_name":"Mother Dairy","company_name":"Mother Dairy","raw_brand_aliases":["Mother Dairy"],"is_enabled":true,"created_at":"2026-11-07T10:19:44.095185+00:00","scope_source":"client"}, 
 {"brand_key":"mr munchies","brand_name":"Mr. Munchies","company_name":"Mr. Munchies","raw_brand_aliases":["Mr.Munchies","Mr Munchies","MrMunchies"],"is_enabled":true,"created_at":"2026-11-06T10:41:07.149977+00:00","scope_source":"client"}]') on conflict do nothing;

insert into silver.dim_platform select * from json_populate_recordset(null::silver.dim_platform, '[{"platform":"blinkit","platform_name":"Blinkit","is_test":false}, 
 {"platform":"demo","platform_name":"Demo (test data)","is_test":true}, 
 {"platform":"instamart","platform_name":"Swiggy Instamart","is_test":false}, 
 {"platform":"jiomart","platform_name":"JioMart","is_test":false}, 
 {"platform":"zepto","platform_name":"Zepto","is_test":false}]') on conflict do nothing;

insert into silver.freshness_policy select * from json_populate_recordset(null::silver.freshness_policy, '[{"source_type":"brand_search","fresh_within_hours":24,"description":"Brand search scrape per dark store (public.search_cards)"}, 
 {"source_type":"category_shelf","fresh_within_hours":72,"description":"Category shelf read per dark store (public.shelf_positions)"}, 
 {"source_type":"stock_check","fresh_within_hours":48,"description":"Product-page stock check per dark store (public.observations)"}]') on conflict do nothing;

insert into silver.ref_noise_word select * from json_populate_recordset(null::silver.ref_noise_word, '[{"word":"and","is_active":true}, 
 {"word":"best","is_active":true}, 
 {"word":"beverage","is_active":true}, 
 {"word":"bottle","is_active":true}, 
 {"word":"buy","is_active":true}, 
 {"word":"can","is_active":true}, 
 {"word":"carbonated","is_active":true}, 
 {"word":"cold","is_active":true}, 
 {"word":"combo","is_active":true}, 
 {"word":"drink","is_active":true}, 
 {"word":"flavored","is_active":true}, 
 {"word":"flavoured","is_active":true}, 
 {"word":"ltr","is_active":true}, 
 {"word":"ml","is_active":true}, 
 {"word":"new","is_active":true}, 
 {"word":"of","is_active":true}, 
 {"word":"online","is_active":true}, 
 {"word":"original","is_active":true}, 
 {"word":"pack","is_active":true}, 
 {"word":"pc","is_active":true}, 
 {"word":"pcs","is_active":true}, 
 {"word":"pet","is_active":true}, 
 {"word":"quality","is_active":true}, 
 {"word":"set","is_active":true}, 
 {"word":"soft","is_active":true}, 
 {"word":"tin","is_active":true}, 
 {"word":"with","is_active":true}]') on conflict do nothing;

insert into silver.ref_variant_synonym select * from json_populate_recordset(null::silver.ref_variant_synonym, '[{"syn_key":"extra large","variant":"xl","is_active":true}, 
 {"syn_key":"no sugar","variant":"zero","is_active":true}, 
 {"syn_key":"sugar free","variant":"zero","is_active":true}, 
 {"syn_key":"zero sugar","variant":"zero","is_active":true}, 
 {"syn_key":"black","variant":"black","is_active":true}, 
 {"syn_key":"blue","variant":"blue","is_active":true}, 
 {"syn_key":"cherry","variant":"cherry","is_active":true}, 
 {"syn_key":"classic","variant":"classic","is_active":true}, 
 {"syn_key":"diet","variant":"diet","is_active":true}, 
 {"syn_key":"gold","variant":"gold","is_active":true}, 
 {"syn_key":"large","variant":"large","is_active":true}, 
 {"syn_key":"lemon","variant":"lime","is_active":true}, 
 {"syn_key":"light","variant":"diet","is_active":true}, 
 {"syn_key":"lime","variant":"lime","is_active":true}, 
 {"syn_key":"lite","variant":"diet","is_active":true}, 
 {"syn_key":"mango","variant":"mango","is_active":true}, 
 {"syn_key":"medium","variant":"medium","is_active":true}, 
 {"syn_key":"nimbu","variant":"lime","is_active":true}, 
 {"syn_key":"orange","variant":"orange","is_active":true}, 
 {"syn_key":"original","variant":"classic","is_active":true}, 
 {"syn_key":"red","variant":"red","is_active":true}, 
 {"syn_key":"regular","variant":"classic","is_active":true}, 
 {"syn_key":"silver","variant":"silver","is_active":true}, 
 {"syn_key":"small","variant":"small","is_active":true}, 
 {"syn_key":"sugarfree","variant":"zero","is_active":true}, 
 {"syn_key":"vanilla","variant":"vanilla","is_active":true}, 
 {"syn_key":"white","variant":"white","is_active":true}, 
 {"syn_key":"xl","variant":"xl","is_active":true}, 
 {"syn_key":"xxl","variant":"xxl","is_active":true}, 
 {"syn_key":"zero","variant":"zero","is_active":true}]') on conflict do nothing;

insert into silver.sidnl_config select * from json_populate_recordset(null::silver.sidnl_config, '[{"key":"alert_claim_timeout_minutes","value_num":5,"value_text":null,"description":"rows stuck in sending longer than this are marked failed (at-most-once)"}, 
 {"key":"alert_delivery_enabled","value_num":0,"value_text":null,"description":"1 = the edge function may deliver outbox rows; 0 = collect only"}, 
 {"key":"alert_max_attempts","value_num":6,"value_text":null,"description":"delivery attempts before an alert row is marked dead"}, 
 {"key":"auto_match_exact_enabled","value_num":1,"value_text":null,"description":"1 = sidnl-auto-match approves pending reviews that are exact cross-platform twins (same brand, same normalized name, same parsed size/unit/pack); 0 = off. Fuzzy matches are never auto-approved."}, 
 {"key":"auto_merge_fuzzy","value_num":0,"value_text":null,"description":"1 = score >= th_auto merges automatically; 0 (default) = only exact brand+name+pack matches merge, fuzzy matches go to match_review_queue"}, 
 {"key":"brand_min_sim","value_num":0.60,"value_text":null,"description":"Check 3 - below this two brands are in conflict"}, 
 {"key":"category_chunk_rows","value_num":50000,"value_text":null,"description":"refresh_category_market reads bronze shelf cards in id chunks of this size"}, 
 {"key":"category_min_stores","value_num":10,"value_text":null,"description":"A category shelf is auto-loaded into silver once it was read OK at this many distinct dark stores"}, 
 {"key":"cron_alert_consecutive_failures","value_num":3,"value_text":null,"description":"Alert when a sidnl-* cron job has this many consecutive failed executions (running executions are ignored)"}, 
 {"key":"cron_history_keep_days","value_num":14,"value_text":null,"description":"sidnl-maintenance deletes cron.job_run_details rows older than this many days (ops.v_cron_health reads 7 days)"}, 
 {"key":"dead_letter_max_per_chunk","value_num":100,"value_text":null,"description":"More rows than this failing in one category chunk means the error is not row-specific: the scope fails instead of dead-lettering"}, 
 {"key":"dead_letter_max_retries","value_num":24,"value_text":null,"description":"After this many failed retries a dead-lettered row stays open but is no longer retried automatically (alert raised)"}, 
 {"key":"dead_letter_retry_minutes","value_num":60,"value_text":null,"description":"Minimum minutes between automatic retries of a dead-lettered bronze row (doubles per attempt, max 24 h)"}, 
 {"key":"dq_reject_block_pct","value_num":5,"value_text":null,"description":"A category scope is BLOCKED when rejected rows (e.g. negative selling price) exceed this % of its shelf rows (systemic issue)"}, 
 {"key":"freshness_lookback_rows","value_num":1000,"value_text":null,"description":"sidnl-freshness re-reads this many bronze ids below its cursor each run (late-committed rows)"}, 
 {"key":"gold_max_attempts","value_num":5,"value_text":null,"description":"Gold (dash) refresh: a transient failure is retried until this many attempts; permanent errors are never retried"}, 
 {"key":"gold_visibility_days","value_num":null,"value_text":null,"description":"Days of dash.visibility rebuilt per gold refresh. NULL = all dates (required: visibility is keyed by sidnl_id and SI ids are renumbered A-Z)"}, 
 {"key":"heartbeat_daily_max_hours","value_num":26,"value_text":null,"description":"max age of last daily run start before heartbeat is overdue"}, 
 {"key":"heartbeat_gold_max_minutes","value_num":10,"value_text":null,"description":"max age of last cron run start for sidnl-gold before heartbeat is overdue"}, 
 {"key":"heartbeat_pipeline_max_minutes","value_num":10,"value_text":null,"description":"max age of last cron run start for sidnl-pipeline before heartbeat is overdue"}, 
 {"key":"incremental_lookback_rows","value_num":5000,"value_text":null,"description":"Incremental parser re-reads this many ids before the watermark (late-committed rows)"}, 
 {"key":"pipeline_min_interval_seconds","value_num":120,"value_text":null,"description":"run_pipeline() will not start again sooner than this after the previous run (incremental loads are cheap)"}, 
 {"key":"reconcile_window_days","value_num":3,"value_text":null,"description":"sidnl-reconcile compares silver facts loaded in the last N days with their bronze rows (dash checks are always full)"}, 
 {"key":"size_tol","value_num":0.05,"value_text":null,"description":"Check 3 - max relative size difference (5%)"}, 
 {"key":"storage_crit_pct","value_num":85,"value_text":null,"description":"Critical when DB+WAL usage exceeds this % of storage_plan_gb"}, 
 {"key":"storage_plan_gb","value_num":8,"value_text":null,"description":"Included disk (GB) of the Supabase Pro plan - confirm in dashboard (Settings > Compute and Disk); adjust if disk is scaled up"}, 
 {"key":"storage_warn_pct","value_num":70,"value_text":null,"description":"Warn when DB+WAL usage exceeds this % of storage_plan_gb"}, 
 {"key":"th_auto","value_num":0.90,"value_text":null,"description":"score >= this AND strict rules pass -> auto-map to existing SI id"}, 
 {"key":"th_review","value_num":0.75,"value_text":null,"description":"score >= this (but not auto) -> new SI id + manual review suggestion"}, 
 {"key":"variant_min_sim","value_num":0.40,"value_text":null,"description":"Check 3 - below this two variants are opposing"}, 
 {"key":"w_brand","value_num":0.25,"value_text":null,"description":"Check 1 - brand similarity weight"}, 
 {"key":"w_category","value_num":0.05,"value_text":null,"description":"Check 2 - category L1/L2/L3 alignment weight"}, 
 {"key":"w_name","value_num":0.35,"value_text":null,"description":"Check 1 - lexical product-name similarity weight"}, 
 {"key":"w_size","value_num":0.20,"value_text":null,"description":"Check 2 - quantity / pack size agreement weight"}, 
 {"key":"w_variant","value_num":0.15,"value_text":null,"description":"Check 2 - variant agreement weight"}]') on conflict do nothing;

select cron.schedule('sidnl-auto-match', '*/10 * * * *', 'set statement_timeout = ''120s''; select silver.auto_approve_exact_matches()');

select cron.schedule('sidnl-dead-letter', '*/15 * * * *', 'set statement_timeout = ''300s''; select silver.retry_dead_letters()');

select cron.schedule('sidnl-freshness', '*/5 * * * *', 'set statement_timeout = ''120s''; select silver.refresh_freshness()');

select cron.schedule('sidnl-gold', '* * * * *', 'set statement_timeout = ''600s''; select silver.run_gold_pending()');

select cron.schedule('sidnl-maintenance', '5 19 * * *', 'set statement_timeout = ''300s''; select silver.run_maintenance()');

select cron.schedule('sidnl-pipeline', '* * * * *', 'set statement_timeout = ''600s''; select silver.run_tick()');

select cron.schedule('sidnl-pipeline-daily', '35 18 * * *', 'select silver.enqueue_daily(''cron-daily'', false)');

select cron.schedule('sidnl-reconcile', '20 19 * * *', 'set statement_timeout = ''900s''; select silver.reconcile()');

select cron.schedule('sidnl-reconcile-coverage', '40 19 * * *', 'set statement_timeout = ''600s''; select silver.reconcile_coverage()');

select cron.schedule('sidnl-store-city', '*/10 * * * *', 'set statement_timeout = ''300s''; select silver.fill_store_cities()');
