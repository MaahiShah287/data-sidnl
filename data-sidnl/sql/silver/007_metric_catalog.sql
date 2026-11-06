-- =============================================================================
-- File:    silver/007_metric_catalog.sql
-- Purpose: Machine-readable map from every metric in the "Business Analytics
--          Metrics & Formulas" PDF to what silver can actually support.
--
--   support = direct         a silver column IS the metric
--             derived        computable from silver with the PDF formula
--             proxy          computable only with a documented stand-in definition
--             partial        part of the formula is computable, part is missing
--             not_available  the source data does not exist in the scrapes
--
-- Query it:  select * from silver.ref_metric_support where support <> 'not_available';
-- =============================================================================

create table if not exists silver.ref_metric_support (
    metric_id     int generated always as identity primary key,
    pdf_section   int  not null,
    section_name  text not null,
    metric        text not null,
    formula       text not null,
    support       text not null check (support in ('direct','derived','proxy','partial','not_available')),
    silver_source text,
    notes         text,
    unique (pdf_section, metric)
);
comment on table silver.ref_metric_support is 'PDF metric -> silver support level, source columns and caveats. Documentation as data.';

truncate silver.ref_metric_support restart identity;

insert into silver.ref_metric_support (pdf_section, section_name, metric, formula, support, silver_source, notes) values
-- 1. Overview -----------------------------------------------------------------
(1,'Overview - Sales, Market & Pricing','Sales value at MRP','Quantity Sold x MRP','not_available',null,'Scrapes show stock and price, not units sold.'),
(1,'Overview - Sales, Market & Pricing','Quantity sold','SUM(units sold)','not_available',null,'No sales feed.'),
(1,'Overview - Sales, Market & Pricing','Market share (%)','Brand Sales / Category Sales x 100','not_available',null,'Needs sales for brand and category.'),
(1,'Overview - Sales, Market & Pricing','Estimated market size','Brand Sales / Market Share','not_available',null,'Needs sales.'),
(1,'Overview - Sales, Market & Pricing','Average selling price (SP)','Total Selling Value / Total Units Sold','proxy','v_reading.selling_price (AVG, dq_status=valid)','Unweighted mean of observed SP: there are no units sold to weight by.'),
(1,'Overview - Sales, Market & Pricing','Discount amount','MRP - SP','direct','fact_product_reading.discount_amount',null),
(1,'Overview - Sales, Market & Pricing','Discount (%)','(MRP - SP) / MRP x 100','direct','fact_product_reading.discount_pct','NULL when MRP is missing or 0 (zero-denominator rule).'),
(1,'Overview - Sales, Market & Pricing','Weighted discount (%)','SUM((MRP-SP) x Qty) / SUM(MRP x Qty) x 100','proxy','v_reading.discount_pct (AVG)','No quantity weights; report as simple average and label it so.'),
(1,'Overview - Sales, Market & Pricing','Brand contribution (%)','Brand Sales / Total Sales x 100','not_available',null,'Needs sales.'),
-- 2. Assortment, listing, availability ----------------------------------------
(2,'Assortment, Listing & Availability','Assortment','COUNT(DISTINCT SKU)','derived','COUNT(DISTINCT product_key) over v_reading where is_listed',null),
(2,'Assortment, Listing & Availability','Assortment coverage (%)','Listed SKUs / Total Target SKUs x 100','partial','dim_product (SKUs seen) ; target list not stored','Confirm what an eligible/target SKU is, then store it (e.g. a target flag on dim_product).'),
(2,'Assortment, Listing & Availability','Dark-store listing (%)','Stores listing SKU / Eligible stores x 100','derived','v_sku_listing.listing_pct','Eligible = stores with a valid latest scan. Floor value when scans stopped early (see eligible_stores_stopped_early).'),
(2,'Assortment, Listing & Availability','Weighted listing (%)','SUM weights listed / SUM weights eligible x 100','not_available',null,'Weighting basis (store sales etc.) not defined and no sales data.'),
(2,'Assortment, Listing & Availability','OSA (%)','Available listed store-SKU obs / Total listed obs x 100','derived','fact_product_reading WHERE osa_eligible: SUM(is_available::int)/COUNT(*)','Product-page stock checks only; brand-search cards only show listed items so they are excluded.'),
(2,'Assortment, Listing & Availability','Weighted OSA (%)','Weighted available obs / total weighted obs x 100','not_available',null,'Weighting basis undefined.'),
(2,'Assortment, Listing & Availability','Average OSA (%)','AVG of daily OSA %','derived','OSA grouped by obs_date, then AVG','For a period rate use SUM(available)/SUM(eligible) instead.'),
(2,'Assortment, Listing & Availability','OSA D-1 / D-2 / D-3','OSA for yesterday / 2 / 3 days ago','derived','OSA grouped by obs_date','Stock checks are run ad hoc, not daily: D-n days may have no data. Gold anchors D-n on the latest date present.'),
-- 3. Inventory ----------------------------------------------------------------
(3,'Inventory & Stock Health','Inventory (FE)','Latest store stock','direct','v_reading_current.inventory_units','Store-level units as displayed; inventory_is_capped marks platform display caps. Check freshness.'),
(3,'Inventory & Stock Health','Inventory (BE)','Latest warehouse stock','not_available',null,'Warehouse stock is not exposed to scrapers.'),
(3,'Inventory & Stock Health','Inventory (FE+BE)','FE + BE','not_available',null,'BE missing.'),
(3,'Inventory & Stock Health','DRR (daily run rate)','Units sold / days','not_available',null,'No units sold. Inventory deltas are not a safe substitute (restocks).'),
(3,'Inventory & Stock Health','DOI (FE / BE / FE+BE)','Inventory / DRR','not_available',null,'Needs DRR.'),
(3,'Inventory & Stock Health','Inventory value / BE inventory value','Units x Unit Cost','not_available',null,'No unit cost.'),
(3,'Inventory & Stock Health','Days to expiry','Expiry Date - Today','not_available',null,'No expiry dates.'),
(3,'Inventory & Stock Health','Slow-moving stock','DRR / DOI threshold rule','not_available',null,'Needs DRR and thresholds.'),
-- 4. POs & fulfilment ---------------------------------------------------------
(4,'Purchase Orders & Fulfilment','PO / GRN / Invoice / DN amounts and units','SUMs of PO, GRN, invoice, DN lines','not_available',null,'Procurement/ERP data is not part of the scrape; needs its own bronze source.'),
(4,'Purchase Orders & Fulfilment','Fulfilment gap, Fill rate (%), Deficit (%), Open POs','PO Units vs GRN Units','not_available',null,'Needs PO + GRN. Use SUM/SUM, not averages of per-PO rates.'),
(4,'Purchase Orders & Fulfilment','Average delivery time, Delivery delay, Scheduled lead time','GRN/PO date differences','not_available',null,'Needs PO + GRN dates.'),
-- 5. Priority / critical / PSL ------------------------------------------------
(5,'Priority POs, Critical SKUs & Potential Loss','Priority','Rule on cover, OSA, sales importance, delay','proxy','OSA + inventory_units from silver; sales/delay missing','Rule thresholds must be agreed (see PDF section 11).'),
(5,'Priority POs, Critical SKUs & Potential Loss','Critical SKUs','COUNT(SKUs meeting critical rule)','proxy','OSA, inventory_units, stock_status','e.g. low OSA or zero FE stock; sales impact missing.'),
(5,'Priority POs, Critical SKUs & Potential Loss','Estimated lost units','Expected demand - actual sales, floor 0','not_available',null,'No demand or sales.'),
(5,'Priority POs, Critical SKUs & Potential Loss','PSL / potential sales loss','Estimated Lost Units x SP','proxy','is_available = false readings x selling_price','Stand-in only: 1 lost unit per current out-of-stock store-SKU. Label as proxy.'),
-- 6. Invoices, payments, debit notes -----------------------------------------
(6,'Invoices, Payments & Debit Notes','GRN / Invoice / Debit-note values, quantity & amount differences','SUMs and differences','not_available',null,'No finance data in scrapes.'),
(6,'Invoices, Payments & Debit Notes','Credit days, Due status','Due Date - Invoice Date','not_available',null,'No finance data.'),
(6,'Invoices, Payments & Debit Notes','Approved amount, TDS, Amount payable, Advance paid, Payment amount','Per PDF section 6','not_available',null,'No finance data.'),
-- 7. Availability RCA ---------------------------------------------------------
(7,'Availability RCA','OSA D-1 / D-2 / D-3','Available / eligible listed obs x 100 per day','derived','OSA grouped by obs_date',null),
(7,'Availability RCA','Sales (MRP)','Units Sold x MRP','not_available',null,'No units sold.'),
(7,'Availability RCA','Sales contribution (%)','SKU Sales / Brand Sales x 100','not_available',null,'No sales.'),
(7,'Availability RCA','Sales impact (%)','Est. Lost Sales / Expected Sales x 100','not_available',null,'Definition unconfirmed and no sales.'),
(7,'Availability RCA','FE / BE inventory','Latest store / warehouse stock','partial','FE: v_reading_current.inventory_units','BE not available.'),
(7,'Availability RCA','DOI','Inventory / DRR','not_available',null,'Needs DRR.'),
(7,'Availability RCA','RCA checks','OSA history, FE, BE, DRR, DOI, open POs','partial','OSA history (obs_date), FE stock, price, listing %','DRR, DOI, BE, open POs unavailable: RCA limited to store-side causes.'),
-- 8. Visibility & keywords ----------------------------------------------------
(8,'Visibility & Keyword Insights','KW VOL (Monthly)','Platform-supplied search volume','not_available',null,'Source metric from retail-media platform; not scraped.'),
(8,'Visibility & Keyword Insights','Overall SOV (%)','Brand impressions / Market impressions x 100','partial','COUNT(*) of brand_search/category_shelf readings = brand impressions','Market impressions need competitor shelf reads: silver is brand-scoped. Add competitors to silver.brand_scope and load category sweeps to get the denominator.'),
(8,'Visibility & Keyword Insights','Organic SOV / Paid SOV (%)','Organic (paid) impressions / market organic (paid) x 100','partial','is_ad flag on readings','Same denominator gap. Never add organic + paid SOV.'),
(8,'Visibility & Keyword Insights','Top of Search SOV (all / organic / paid)','Top-of-search impressions share','partial','search_position, organic_position, is_ad','Define the top-N cut-off, and the denominator gap applies.'),
(8,'Visibility & Keyword Insights','Category Impression Share','Brand / Category impressions x 100','partial','category via dim_category','Category totals need non-brand shelf reads.'),
(8,'Visibility & Keyword Insights','Competitor market share / discount / average SP','Competitor sales, (MRP-SP)/MRP, SP / units','partial','Discount and SP work once a competitor brand is in brand_scope','Competitor sales-based share is not_available.'),
(8,'Visibility & Keyword Insights','Ad spend','SUM(ad spend)','not_available',null,'No retail-media spend feed.'),
(8,'Visibility & Keyword Insights','Top cities / top SKUs','Rank by sales, OSA, SOV, availability','derived','v_reading / v_sku_listing grouped by city_slug, product_key','Rank by OSA, listing %, impressions (not sales).'),
-- 9. Pricing / price parity ---------------------------------------------------
(9,'Pricing - Price Parity','MRP','Stored MRP','direct','fact_product_reading.mrp',null),
(9,'Pricing - Price Parity','SP','Platform selling price','direct','fact_product_reading.selling_price',null),
(9,'Pricing - Price Parity','Discount amount / Discount (%)','MRP - SP ; /MRP','direct','discount_amount, discount_pct',null),
(9,'Pricing - Price Parity','Price difference / Price difference (%)','Platform SP - Reference SP ; / Reference SP','partial','selling_price per platform x store x city','Only Blinkit is loaded: parity works across stores/cities now, across platforms once Zepto/Instamart rows exist.'),
(9,'Pricing - Price Parity','Threshold difference','SP - Configured Threshold','derived','selling_price','Threshold is configuration, not stored in silver yet.');
