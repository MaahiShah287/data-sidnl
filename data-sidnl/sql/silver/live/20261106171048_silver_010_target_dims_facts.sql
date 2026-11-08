create table if not exists silver.dim_date (
    date_key    date primary key,
    year        smallint not null,
    quarter     smallint not null,
    month       smallint not null,
    month_name  text     not null,
    week_of_year smallint not null,
    day_of_week smallint not null,
    is_weekend  boolean  not null
);
insert into silver.dim_date
select d::date, extract(year from d), extract(quarter from d), extract(month from d), to_char(d, 'FMMonth'),
       extract(week from d), extract(isodow from d), extract(isodow from d) in (6, 7)
from generate_series('2025-01-01'::date, '2030-12-31'::date, interval '1 day') d
on conflict do nothing;
create table if not exists silver.dim_warehouse (
    warehouse_key         int generated always as identity primary key,
    platform              text not null references silver.dim_platform(platform),
    warehouse_external_id text not null,
    warehouse_name        text,
    city_slug             text references silver.dim_city(city_slug),
    unique (platform, warehouse_external_id)
);
create table if not exists silver.dim_supplier (
    supplier_key  int generated always as identity primary key,
    supplier_name text not null unique,
    brand_key     text references silver.dim_brand(brand_key)
);
create table if not exists silver.dim_keyword (
    keyword_key int generated always as identity primary key,
    platform    text not null references silver.dim_platform(platform),
    keyword     text not null,
    keyword_type text check (keyword_type in ('brand', 'generic', 'competitor')),
    unique (platform, keyword)
);
create table if not exists silver.fact_sales_daily (
    sales_key        bigint generated always as identity primary key,
    sale_date        date   not null references silver.dim_date(date_key),
    platform         text   not null references silver.dim_platform(platform),
    product_key      int    not null references silver.dim_product(product_key),
    store_key        int    references silver.dim_store(store_key),
    city_slug        text   references silver.dim_city(city_slug),
    units_sold       int    not null check (units_sold >= 0),
    gmv_mrp          numeric(14,2),
    net_sales        numeric(14,2),
    orders           int,
    source_record_id text,
    ingest_batch_id  bigint references public.vp_ingest_batch(batch_id),
    etl_run_id       bigint references silver.etl_run(run_id),
    loaded_at        timestamptz not null default now(),
    unique nulls not distinct (platform, product_key, store_key, sale_date)
);
comment on table silver.fact_sales_daily is 'Units and value sold per SKU x store x day (vendor portal). Feeds sales, market share, ASP, weighted discount, DRR, PSL.';
create table if not exists silver.fact_inventory_snapshot (
    inventory_key   bigint generated always as identity primary key,
    snapshot_date   date not null references silver.dim_date(date_key),
    observed_at     timestamptz,
    platform        text not null references silver.dim_platform(platform),
    product_key     int  not null references silver.dim_product(product_key),
    location_type   text not null check (location_type in ('FE', 'BE')),
    store_key       int  references silver.dim_store(store_key),
    warehouse_key   int  references silver.dim_warehouse(warehouse_key),
    units           int  not null check (units >= 0),
    batch_no        text,
    expiry_date     date,
    unit_cost       numeric(12,2),
    cost_includes_tax boolean,
    source_record_id text,
    ingest_batch_id bigint references public.vp_ingest_batch(batch_id),
    etl_run_id      bigint references silver.etl_run(run_id),
    loaded_at       timestamptz not null default now(),
    check ((location_type = 'FE' and store_key is not null) or (location_type = 'BE' and warehouse_key is not null))
);
comment on table silver.fact_inventory_snapshot is 'FE (store) and BE (warehouse) stock per SKU per day with batch, expiry and cost. Feeds inventory, DOI, inventory value, days to expiry.';
create table if not exists silver.fact_po_line (
    po_line_key     bigint generated always as identity primary key,
    po_number       text not null,
    po_line_no      int  not null default 1,
    po_date         date not null references silver.dim_date(date_key),
    platform        text not null references silver.dim_platform(platform),
    supplier_key    int  references silver.dim_supplier(supplier_key),
    warehouse_key   int  references silver.dim_warehouse(warehouse_key),
    product_key     int  not null references silver.dim_product(product_key),
    ordered_units   int  not null check (ordered_units >= 0),
    unit_cost       numeric(12,2),
    po_amount       numeric(14,2),
    tax_amount      numeric(14,2),
    scheduled_date  date references silver.dim_date(date_key),
    po_status       text,
    is_open         boolean,
    priority        text check (priority in ('High', 'Medium', 'Low')),
    source_record_id text,
    ingest_batch_id bigint references public.vp_ingest_batch(batch_id),
    etl_run_id      bigint references silver.etl_run(run_id),
    loaded_at       timestamptz not null default now(),
    unique (platform, po_number, po_line_no)
);
create table if not exists silver.fact_grn_line (
    grn_line_key     bigint generated always as identity primary key,
    grn_number       text not null,
    grn_line_no      int  not null default 1,
    po_line_key      bigint references silver.fact_po_line(po_line_key),
    grn_date         date not null references silver.dim_date(date_key),
    actual_delivery_date date references silver.dim_date(date_key),
    platform         text not null references silver.dim_platform(platform),
    warehouse_key    int  references silver.dim_warehouse(warehouse_key),
    product_key      int  not null references silver.dim_product(product_key),
    received_units   int  not null check (received_units >= 0),
    rejected_units   int  default 0,
    grn_amount       numeric(14,2),
    tax_amount       numeric(14,2),
    source_record_id text,
    ingest_batch_id  bigint references public.vp_ingest_batch(batch_id),
    etl_run_id       bigint references silver.etl_run(run_id),
    loaded_at        timestamptz not null default now(),
    unique (platform, grn_number, grn_line_no)
);
create table if not exists silver.fact_invoice (
    invoice_key      bigint generated always as identity primary key,
    invoice_number   text not null,
    invoice_line_no  int  not null default 1,
    invoice_date     date not null references silver.dim_date(date_key),
    due_date         date references silver.dim_date(date_key),
    platform         text not null references silver.dim_platform(platform),
    supplier_key     int  references silver.dim_supplier(supplier_key),
    po_line_key      bigint references silver.fact_po_line(po_line_key),
    grn_line_key     bigint references silver.fact_grn_line(grn_line_key),
    product_key      int  references silver.dim_product(product_key),
    invoice_qty      int,
    invoice_amount   numeric(14,2),
    tax_amount       numeric(14,2),
    amount_incl_tax  numeric(14,2),
    credit_days      int,
    approved_amount  numeric(14,2),
    tds_amount       numeric(14,2),
    source_record_id text,
    ingest_batch_id  bigint references public.vp_ingest_batch(batch_id),
    etl_run_id       bigint references silver.etl_run(run_id),
    loaded_at        timestamptz not null default now(),
    unique (platform, invoice_number, invoice_line_no)
);
create table if not exists silver.fact_debit_note (
    dn_key           bigint generated always as identity primary key,
    dn_number        text not null,
    dn_date          date not null references silver.dim_date(date_key),
    dn_type          text check (dn_type in ('debit', 'delivery')),
    platform         text not null references silver.dim_platform(platform),
    invoice_key      bigint references silver.fact_invoice(invoice_key),
    grn_line_key     bigint references silver.fact_grn_line(grn_line_key),
    product_key      int  references silver.dim_product(product_key),
    dn_qty           int,
    dn_amount        numeric(14,2),
    tax_amount       numeric(14,2),
    amount_incl_tax  numeric(14,2),
    reason           text,
    source_record_id text,
    ingest_batch_id  bigint references public.vp_ingest_batch(batch_id),
    etl_run_id       bigint references silver.etl_run(run_id),
    loaded_at        timestamptz not null default now()
);
create table if not exists silver.fact_payment (
    payment_key      bigint generated always as identity primary key,
    payment_ref      text,
    payment_date     date not null references silver.dim_date(date_key),
    platform         text not null references silver.dim_platform(platform),
    invoice_key      bigint references silver.fact_invoice(invoice_key),
    po_line_key      bigint references silver.fact_po_line(po_line_key),
    payment_amount   numeric(14,2) not null,
    is_advance       boolean not null default false,
    deductions       numeric(14,2) default 0,
    source_record_id text,
    ingest_batch_id  bigint references public.vp_ingest_batch(batch_id),
    etl_run_id       bigint references silver.etl_run(run_id),
    loaded_at        timestamptz not null default now()
);
create table if not exists silver.fact_ad_keyword_daily (
    ad_key           bigint generated always as identity primary key,
    ad_date          date not null references silver.dim_date(date_key),
    platform         text not null references silver.dim_platform(platform),
    keyword_key      int  not null references silver.dim_keyword(keyword_key),
    brand_key        text references silver.dim_brand(brand_key),
    product_key      int  references silver.dim_product(product_key),
    city_slug        text references silver.dim_city(city_slug),
    ad_type          text,
    impressions      bigint,
    clicks           bigint,
    orders           int,
    ad_spend         numeric(14,2),
    ad_sales         numeric(14,2),
    kw_volume_monthly bigint,
    source_record_id text,
    ingest_batch_id  bigint references public.vp_ingest_batch(batch_id),
    etl_run_id       bigint references silver.etl_run(run_id),
    loaded_at        timestamptz not null default now()
);
create table if not exists silver.fact_category_sales (
    cat_sales_key    bigint generated always as identity primary key,
    period_start     date not null references silver.dim_date(date_key),
    period_end       date not null references silver.dim_date(date_key),
    platform         text not null references silver.dim_platform(platform),
    category_key     int  not null references silver.dim_category(category_key),
    city_slug        text references silver.dim_city(city_slug),
    brand_key        text references silver.dim_brand(brand_key),
    category_sales   numeric(16,2),
    category_units   bigint,
    brand_sales      numeric(16,2),
    brand_share_pct  numeric(7,3),
    source_record_id text,
    ingest_batch_id  bigint references public.vp_ingest_batch(batch_id),
    etl_run_id       bigint references silver.etl_run(run_id),
    loaded_at        timestamptz not null default now()
);
create index if not exists ix_sales_product_date on silver.fact_sales_daily (product_key, sale_date);
create index if not exists ix_inv_product_date   on silver.fact_inventory_snapshot (product_key, snapshot_date);
create index if not exists ix_po_product         on silver.fact_po_line (product_key, po_date);
create index if not exists ix_grn_po             on silver.fact_grn_line (po_line_key);
create index if not exists ix_inv_po             on silver.fact_invoice (po_line_key);
create index if not exists ix_dn_invoice         on silver.fact_debit_note (invoice_key);
create index if not exists ix_pay_invoice        on silver.fact_payment (invoice_key);
create index if not exists ix_ad_kw_date         on silver.fact_ad_keyword_daily (keyword_key, ad_date);
create index if not exists ix_catsales_cat       on silver.fact_category_sales (category_key, period_start);
do $$
declare t record;
begin
    for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'silver' and c.relkind = 'r' loop
        execute format('alter table silver.%I enable row level security', t.relname);
    end loop;
end $$;