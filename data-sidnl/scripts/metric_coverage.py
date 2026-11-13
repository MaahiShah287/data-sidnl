"""Metric coverage: which of the 171 handbook metrics are visible in the portal, which are not, and why.

    python scripts/metric_coverage.py

Source of truth = the table below ("Quick-Commerce Metric Formula Dictionary", 171 metrics, 13 sections).
Writes:
  portal/src/lib/metricCoverage.json        read by the portal page /metrics
  docs/METRIC_COVERAGE_<date>.md            the report (counts, per-section tables, what unblocks what)

Status (decided by what is wired to a page, not by what is theoretically possible):
  live     computed from a feed we have and shown on a portal page
  proxy    shown, but it is a proxy and labelled so (the handbook allows this with a label)
  partial  some parts shown, the rest needs something we do not have
  feed     NOT visible: needs a feed or configuration that does not exist yet (the portal shows "Not available")

State of the database when this was generated (2026-11-13 07:05 UTC): silver_075, silver_076 (the two parts of the
platform_listings bronze-drift fix), dash_013 (competitor tables) and dash_014 (cron re-register) are all APPLIED. The silver
pipeline has run successfully since run 1681 (07:00-07:02 UTC), the gold tables were refreshed at 07:02, and the competitor
tables refresh every 10 minutes. Mr. Munchies' Zepto stock checks (3.7 k readings, 480 stores) are loaded. Still not fixed:
silver.refresh_scrape_context (cron sidnl-context) reads other dropped platform_listings columns (separate failure).
"""
import datetime
import json
import pathlib
from collections import Counter, defaultdict

ROOT = pathlib.Path(__file__).resolve().parent.parent
TODAY = "2026-11-13"

SECTIONS = {
    1: "Overview & Business Performance", 2: "Availability Insights", 3: "RAC - Issue & Resolution Analytics",
    4: "EDI Monitoring", 5: "Inventory, Expiry & Forecasting", 6: "Purchase Orders", 7: "Invoice & Finance",
    8: "Price Overview & Price Parity", 9: "Ads Insights", 10: "Automations", 11: "Keyword Search",
    12: "Visibility Overview", 13: "Darkstore Map & Distribution Planning",
}

# (no, name, status, page, plat, dep, needs, note)
M = []
def r(no, name, status, page="", plat="", dep="", needs="", note=""):
    M.append(dict(n=no, name=name, status=status, page=page, plat=plat, dep=dep, needs=needs, note=note))

ORD, FIN, INV, PO, EDI, FC, TK, AUTO, SHIP = ("Orders / sales feed", "Finance feed", "Inventory ledger", "PO + GRN feed",
    "EDI gateway log", "Forecast feed", "Issue / ticket log", "Automation registry", "Shipment / TMS feed")

# ---- 1 Overview & business performance --------------------------------------------------------------------------
r(1, "GMV", "feed", needs=ORD, note="Scraped price x availability must never be used to estimate sales.")
r(2, "Net Sales", "feed", needs=ORD)
r(3, "Units Sold", "feed", needs=ORD)
r(4, "ASP (Average Selling Price)", "proxy", "Pricing", "B+Z", needs=ORD,
  note="Shows the observed average selling price (unweighted); true ASP = net sales / net units.")
r(5, "Market Share", "proxy", "Competitors", "B+Z", "dash_013", ORD + " + market total",
  note="Share of shelf, labelled Proxy Share. Real share needs orders and a market total.")
r(6, "Contribution Margin", "feed", needs=FIN)
r(7, "Sales Performance", "feed", needs=ORD + " + targets")
r(8, "Marketplace Contribution", "feed", needs=ORD)
r(9, "Business Health - Sales", "feed", needs=ORD)
r(10, "Business Health - Profitability", "feed", needs=FIN + " + orders")
r(11, "Business Health - Availability", "proxy", "Overview, Availability", "B+Z", needs="OSA location weights",
  note="Observed OSA shown unweighted (weighting basis is a sign-off item).")
r(12, "Business Health - Supply", "feed", needs=PO)
r(13, "Business Health - Finance", "feed", needs=FIN)
r(14, "Business Health - Advertising", "partial", "Ads", "B (1P)", needs="Zepto ads export",
  note="Blinkit ROAS live; Zepto first-party ads not delivered yet.")
r(15, "Business Health - Visibility", "proxy", "Visibility, Competitors", "B+Z", "dash_013",
  note="Average rank, top-10 rate, listing coverage and share of shelf side by side; no composite score.")
r(16, "Business Health - Pricing", "proxy", "Pricing, Competitors", "B+Z", "dash_013",
  note="Observed discount live; price index vs competitors is brand-level.")
r(17, "Top SKU at Risk", "feed", needs="Sales + inventory + margin + expiry")
r(18, "Advertisement Performance", "partial", "Ads", "B (1P)", needs="Clicks / orders in the export; Zepto ads export",
  note="Blinkit spend, sales, ROAS, impressions live; CTR, CPC, conversion not in the export.")
r(19, "Availability & Stock-Outs", "partial", "Availability, Competitors", "B+Z", "dash_013",
  note="Stock-out rate (100 - OSA) live for client and competitor brands; stock-out duration not computed.")
r(20, "City Performance", "partial", "Availability, Pricing, Competitors", "B+Z", needs=ORD,
  note="City OSA, price and shelf share live; city sales and growth need orders.")
r(21, "Marketing & Finance", "feed", needs=FIN + " + ads attribution")
r(22, "Needs Your Attention", "partial", "Availability", "B+Z", needs=TK + " + severity thresholds",
  note="Critical SKU-city list shown; alert count and priority score need severity / impact / age rules.")

# ---- 2 Availability ----------------------------------------------------------------------------------------------
r(23, "Assortment", "partial", "Availability, Competitors", "B+Z", "dash_013", "Expected-assortment master list",
  note="SKU count per brand live; coverage % needs the expected SKU list.")
r(24, "Observed OSA (On-Shelf Availability)", "live", "Availability, Competitors", "B+Z", "dash_013")
r(25, "DOI (Days of Inventory)", "feed", needs=INV + " + orders", note="Never estimated from scraped availability.")
r(26, "DS Listing (Dark-Store Listing)", "live", "Availability, Competitors", "B+Z", "dash_013",
  note="Stores where the SKU/brand was listed / stores scanned.")
r(27, "Weighted OSA in Listing (LS)", "proxy", "Availability", "B+Z", needs="SKU weights",
  note="OSA in listed stores, unweighted.")
r(28, "Category Insights", "partial", "Availability, Competitors", "B+Z", "dash_013", ORD,
  note="Category OSA and assortment live; category sales need orders.")
r(29, "SKU Insights", "partial", "Availability, Pricing, Competitors", "B+Z", "dash_013", INV + " + orders",
  note="OSA %, latest MRP/SP, discount, price trend live; DOI needs stock and sales.")
r(30, "City Insights", "live", "Availability, Competitors", "B+Z", "dash_013")

# ---- 3 RAC -------------------------------------------------------------------------------------------------------
r(31, "SKUs with Observed Stock-Outs", "live", "Availability, Competitors", "B+Z", "dash_013")
for no, name in [(32, "Critical Issues"), (33, "Average Resolution Time"), (34, "Repeated Issues"),
                 (36, "Root-Cause Distribution"), (37, "Issues by Marketplace"), (38, "Issue Frequency Over Time")]:
    r(no, name, "feed", needs=TK)
r(35, "Estimated Impact of Unresolved Issues", "feed", needs=TK + " + sales")
r(39, "SKU x City Matrix", "partial", "Availability", "B+Z", needs=TK + " + sales",
  note="OOS rate and count per SKU-city live; open issues and sales at risk missing.")
r(40, "Warehouse Issues", "feed", needs="Warehouse stock + " + TK)
r(41, "PO (RAC Purchase-Order View)", "feed", needs=PO + " + " + TK)

# ---- 4 EDI -------------------------------------------------------------------------------------------------------
for no, name in [(42, "Total EDI Messages"), (43, "Successfully Processed"), (44, "Failed Messages"),
                 (45, "Pending Acknowledgement"), (46, "Average Processing Time"), (47, "Message Volume Over Time"),
                 (48, "Success vs. Failure Rate"), (49, "Error Category Distribution"), (50, "Processing Time Trend"),
                 (51, "EDI Document Monitoring")]:
    r(no, name, "feed", needs=EDI)

# ---- 5 Inventory, expiry, forecasting ---------------------------------------------------------------------------
for no, name, need in [(52, "Units You Own", INV), (53, "Stock Value at Cost", INV + " + cost master"),
                       (54, "Days of Stock in DS", "Dark-store stock + sales"), (55, "Money Stuck in Unsold Stock", INV + " + sales + cost"),
                       (56, "Stock by Product & City", INV), (57, "Warehouse Stock", INV), (58, "Not Selling", "Sales + " + INV),
                       (59, "Expiry - Need Attention", "Batch inventory"), (60, "Stock Value by Shelf Life", "Batch inventory"),
                       (61, "Batches", "Batch / GRN ledger"), (62, "Forecast Accuracy - Last 8 Weeks", FC + " + sales"),
                       (63, "Forecast Status - In Use", FC), (64, "Forecast Status - Use With Care", FC),
                       (65, "Forecast Status - Not Used", FC), (66, "Next 4 Weeks by City", FC), (67, "Next 16 Weeks Across India", FC)]:
    r(no, name, "feed", needs=need)

# ---- 6 Purchase orders -------------------------------------------------------------------------------------------
for no, name in [(68, "PO Value"), (69, "Fill Rate"), (71, "Total POs"), (72, "Pending POs"), (73, "Accepted POs"),
                 (74, "Partially Fulfilled POs"), (75, "Overdue POs"), (76, "PO Fulfilment Rate"), (77, "PO Status Distribution"),
                 (78, "PO Volume Over Time"), (79, "On-Time Delivery Trend"), (80, "Ordered vs. Delivered Qty"),
                 (81, "Marketplace-Wise Fulfilment"), (82, "PO Insights"), (83, "SKU Insights (PO)")]:
    r(no, name, "feed", needs=PO)
r(70, "Potential Sales Loss", "feed", needs=PO + " + stock + forecast")

# ---- 7 Invoice & finance -----------------------------------------------------------------------------------------
for no, name, need in [(84, "GRN Value", PO), (85, "Invoice Value", "Invoice lines"), (86, "Debit Note Value", "Debit-note ledger"),
                       (87, "Total Invoice Value", "Invoice headers"), (88, "Pending Invoices", "Invoices + payments"),
                       (89, "Overdue Invoices", "Invoices + payments"), (90, "Disputed Invoices", "Dispute workflow"),
                       (91, "Invoice Mismatch Value", "3-way match (invoice / PO / GRN)"), (92, "Invoice Value Over Time", "Invoice headers"),
                       (93, "Paid vs. Pending vs. Overdue", "Invoices + payments"), (94, "Marketplace-Wise Invoice Value", "Invoice headers"),
                       (95, "Invoice Ageing", "Invoices + payments"), (96, "Invoice Details", "Invoices + PO + GRN + payments")]:
    r(no, name, "feed", needs=need)

# ---- 8 Price ------------------------------------------------------------------------------------------------------
r(97, "Observed Selling Price", "live", "Pricing, Competitors", "B+Z", "dash_013")
r(98, "Observed Discount", "live", "Pricing, Competitors", "B+Z", "dash_013")
r(99, "Observed Price per 100g", "live", "Pricing, Competitors", "B+Z", "dash_013", note="g and ml packs; piece packs have no unit price.")
r(100, "Estimated Market Share", "proxy", "Competitors", "B+Z", "dash_013", "Market panel / sales",
  note="Share of shelf, labelled Proxy Share.")
r(101, "MRP and SP", "live", "Pricing, Competitors", "B+Z", "dash_013")
r(102, "Discount Movement", "live", "Pricing", "B+Z", note="Discount trend by day; change in points is stored per SKU.")
r(103, "Competitor Benchmarking", "proxy", "Competitors", "B+Z", "dash_013", "Verified SKU match table",
  note="Brand-level median unit price, not SKU-to-SKU.")
r(104, "Price Recommendations", "feed", needs="COGS, fees and elasticity assumptions")
r(105, "Biggest Price Increase", "live", "Pricing, Competitors", "B+Z", "dash_013", note="Client brands on Pricing, competitors on Competitors.")
r(106, "Biggest Price Decreases", "live", "Pricing, Competitors", "B+Z", "dash_013")
r(107, "Category Insights (Pricing)", "proxy", "Competitors", "B+Z", "dash_013", "Verified SKU match table",
  note="Only categories where a client brand is listed (Frozen Veg Snacks today).")
r(108, "City Insights (Pricing)", "live", "Pricing, Competitors", "B+Z", "dash_013")
r(109, "SKU Insights (Pricing)", "partial", "Competitors, Pricing", "B+Z", "dash_013", "Verified SKU match table",
  note="Latest MRP/SP, discount, unit price, price change; competitor gap per SKU needs the match table.")
r(110, "Price Parity Score", "proxy", "Competitors", "B+Z", "dash_013", "Verified SKU match table",
  note="100 - average |gap %| over competitor brands.")
r(111, "Price Gap by Competitor", "proxy", "Competitors", "B+Z", "dash_013", "Verified SKU match table")
r(112, "Parity Alerts", "partial", "Pricing", "B+Z", needs="Alert thresholds + rule log",
  note="Parity-break flag shown; threshold / match-confidence rules not built.")
r(113, "Cross-Marketplace Comparison", "live", "Competitors", "B+Z", "dash_013", note="Exact brand + name + pack matches only; Zepto side needs silver_075.")
r(114, "Price Gap Analysis", "proxy", "Competitors", "B+Z", "dash_013", "Target parity band from owner")
r(115, "Largest Gap by SKU", "partial", "Competitors", "B+Z", "dash_013", "Verified SKU match table",
  note="Cross-marketplace SKU gaps live; competitor SKU gaps need the match table.")
r(116, "Largest Gap by Keyword", "feed", needs="Keyword -> product capture for competitors")
r(117, "Largest Gap by Category", "partial", "Competitors", "B+Z", "dash_013", "Category shelves where no client brand is listed",
  note="Categories with a client brand only.")
r(118, "Keyword Price Comparison", "feed", needs="Keyword -> product capture for competitors")
r(119, "City Price Comparison", "live", "Pricing, Competitors", "B+Z", "dash_013")
r(120, "Price Changes on the Shelf", "live", "Pricing, Competitors", "B+Z", "dash_013", note="Reflects scrape intervals, not exact change times.")

# ---- 9 Ads (first-party exports; Blinkit loaded, Zepto not yet) -------------------------------------------------
for no, name in [(121, "Total Ad Spend"), (122, "Attributed Sales"), (123, "ROAS (Return on Ad Spend)"), (124, "Impressions"),
                 (129, "Ad Spend vs. Attributed Sales"), (130, "ROAS Trend")]:
    r(no, name, "live", "Ads", "B (1P)", needs="Zepto ads export", note="Blinkit live; Zepto when its export arrives.")
for no, name in [(125, "Clicks"), (126, "CTR (Click-Through Rate)"), (127, "CPC (Cost Per Click)"),
                 (128, "Conversion Rate (CVR)"), (132, "CTR vs. Conversion Rate"), (135, "Ad Recommendations")]:
    r(no, name, "feed", needs="Clicks / orders columns in the ad exports", note="The Blinkit export has no clicks or orders.")
r(131, "Impressions and Clicks", "partial", "Ads", "B (1P)", needs="Clicks column", note="Impressions live; clicks and CTR missing.")
r(133, "Marketplace-Wise Ad Performance", "partial", "Ads", "B (1P)", needs="Zepto ads export")
r(134, "Campaign Performance", "partial", "Ads", "B (1P)", needs="Clicks / orders columns",
  note="Budget, claimables, spend, sales, ROAS, impressions live; clicks, CPC, conversion missing.")
r(136, "Campaign Insights", "partial", "Ads", "B (1P)", needs="Comparable periods for marginal ROAS",
  note="Spend, sales, ROAS and trends live; spend / sales share and marginal ROAS not shown.")

# ---- 10 Automations ----------------------------------------------------------------------------------------------
for no, name in [(137, "Active Rules"), (138, "Triggers"), (139, "Success Rate"), (140, "Failed Executions"), (141, "Rules List")]:
    r(no, name, "feed", needs=AUTO)

# ---- 11 Keyword search --------------------------------------------------------------------------------------------
r(142, "Keywords Tracked", "partial", "Visibility", "B+Z", needs="Keyword registry", note="Observed search terms listed; no registry with active status.")
r(143, "Generating Clicks", "feed", needs="Clicks per keyword")
r(144, "Top Performing Keywords", "live", "Ads", "B (1P)", needs="Zepto ads export", note="Ranked by spend with ROAS shown.")
r(145, "Keyword CTR", "feed", needs="Keyword clicks")
r(146, "Keyword Conversion", "feed", needs="Keyword clicks / orders")
r(147, "Average CPC (Keyword)", "feed", needs="Keyword clicks")
r(148, "Keyword ROAS", "live", "Ads", "B (1P)", needs="Zepto ads export")
r(149, "Share of Voice (Keyword)", "proxy", "Ads, Visibility", "B (1P) + B/Z scraped", needs="Search impressions",
  note="Sponsored SoV from the ads export; organic is a rank proxy.")
r(150, "Keyword Opportunities", "feed", needs="Search volume + conversion data")
r(151, "Search Term Opportunity Matrix", "feed", needs="Search volume, CTR, CVR, competition")
r(152, "Keyword Performance Ranking", "live", "Ads", "B (1P)", needs="Zepto ads export")
r(153, "Keyword Spend vs. Attributed Sales", "live", "Ads", "B (1P)", needs="Zepto ads export")
r(154, "Keyword CTR Trends", "feed", needs="Keyword clicks and impressions by day")
r(155, "Keyword Ranking Trend", "partial", "Visibility", "B+Z", needs="Trend chart", note="Ranks are stored by day; the page shows the latest day only.")
r(156, "Keywords Catalogue", "partial", "Visibility", "B+Z", needs="Keyword registry", note="Latest observation per keyword and SKU.")

# ---- 12 Visibility ------------------------------------------------------------------------------------------------
r(157, "Average Search Rank", "live", "Visibility, Competitors", "B+Z", "dash_013")
r(158, "Share of Search", "proxy", "Visibility, Competitors", "B+Z", "dash_013", "Search impressions / volume",
  note="Share of shelf cards (Proxy).")
r(159, "Top 10 Placements", "live", "Competitors", "B+Z", "dash_013", note="Organic cards at position <= 10 / organic cards.")
r(160, "Listing Coverage", "live", "Visibility, Competitors", "B+Z", "dash_013")
r(161, "Search Rank Trend", "partial", "Visibility", "B+Z", needs="Trend chart", note="Stored by day; latest day shown.")
r(162, "Marketplace Visibility", "live", "Visibility", "B+Z", note="Platform filter shows each marketplace on its own.")
r(163, "Share of Voice (Visibility)", "proxy", "Visibility", "B+Z", needs="Search impressions", note="Share of cards, labelled proxy.")
r(164, "Brand-Wise Share of Search", "proxy", "Visibility, Competitors", "B+Z", "dash_013", "Search impressions", note="Every brand on the category shelf.")
r(165, "Missing Listing Attributes", "feed", needs="Required-attribute schema per category")
r(166, "Keyword Tracking", "partial", "Header banner", "B+Z", needs="Keyword registry", note="Platform freshness banner only; keyword coverage not shown.")
r(167, "SKU Listing Health Audit", "feed", needs="Required-attribute schema + validation rules")

# ---- 13 Darkstore map & distribution -------------------------------------------------------------------------------
r(168, "Darkstore Map", "partial", "", "B+Z", needs="Map page", note="Store coordinates and coverage are in the database; no map page yet.")
r(169, "Distribution Plans", "feed", needs=SHIP)
r(170, "Days of Stock by City", "feed", needs=INV + " + sales")
r(171, "Shipments", "feed", needs=SHIP)

# ---- first-party feeds loaded 2026-11-13 (dash.fp_* tables, views in sql/migrations/dash_016_fp_metric_views.sql) -----
# Zepto seller-portal exports: sales overview, product performance, PO, GRN, invoices, payments, debit notes, ledger,
# ad-console page report and ad-wallet ledger. The Blinkit ad exports were removed from the database on request, so the
# keyword- and campaign-level ad metrics that depended on them are back to "feed" until a keyword-level export is loaded.
# live    = computed from a loaded feed at the metric's stated grain and shown on a page
# partial = shown at a coarser grain, or part of the formula is missing (the note says which part)
def ov(no, status, page="", plat="", needs="", note=""):
    for m in M:
        if m["n"] == no:
            m.update(status=status, page=page, plat=plat, dep="", needs=needs, note=note)
            return
    raise KeyError(no)

Z1 = "Z (1P)"
# sales / stock
ov(1, "live", "Sales", Z1, note="Gross GMV from the sales export (before discounts and refunds); date x city x SKU.")
ov(2, "feed", needs="Refunds / discounts in the sales export", note="The export has gross GMV only.")
ov(3, "live", "Sales", Z1, note="Units from the sales export (no returned-unit column, so gross units).")
ov(4, "live", "Sales, Pricing", Z1 + " + B+Z scraped", note="Sales page: gross ASP = GMV / units. Pricing page: observed shelf price (labelled).")
ov(7, "partial", "Sales", Z1, needs="Sales targets", note="Growth % vs the previous 28 days shown; target achievement needs targets.")
ov(8, "feed", needs="Orders from a second marketplace", note="Only Zepto first-party sales are loaded.")
ov(9, "partial", "Sales", Z1, needs="Net sales + targets", note="GMV, units, ASP and growth side by side; net sales and target achievement not available.")
ov(20, "live", "Sales, Availability, Competitors", Z1 + " + B+Z scraped", note="City GMV share and growth vs previous 28 days (gross GMV).")
ov(25, "partial", "Sales", Z1, needs="Warehouse / city stock", note="National days of inventory per SKU = stock on hand / average daily units (28 days).")
ov(28, "partial", "Availability, Competitors, Sales", "B+Z + Z (1P)", needs="Multi-category sales", note="Sales export has one category (Frozen Food).")
ov(29, "partial", "Availability, Pricing, Competitors, Sales", "B+Z + Z (1P)", needs="City-level stock", note="Now includes GMV, units, stock and days of inventory; stock is national.")
ov(53, "partial", "Sales", Z1, needs="Warehouse / city stock", note="National stock on hand x latest landing cost per SKU.")
ov(58, "partial", "Sales", Z1, needs="City / warehouse stock", note="SKUs with stock and no sales in 28 days (national).")
# purchase orders / goods receipts
ov(12, "partial", "Supply", Z1, needs="Confirmed committed delivery date", note="Supply fulfilment % shown; on-time % not asserted (delivery-date definition unconfirmed).")
ov(68, "live", "Supply", Z1, note="Ordered qty x landing cost, per PO.")
ov(69, "live", "Supply", Z1, note="Sum received / sum ordered; PO lines never received count as fully short.")
ov(71, "live", "Supply", Z1, note="81 POs in the GRN export (all Expired or Locked).")
ov(74, "partial", "Supply", Z1, needs="Open POs", note="Partially received POs counted; every PO in the export is already closed.")
ov(75, "partial", "Supply", Z1, needs="Open POs + grace days", note="Short-received POs shown; the exports contain no open POs to be overdue.")
ov(76, "live", "Supply", Z1, note="Fully received POs / POs, shown beside the unit fill rate.")
ov(77, "live", "Supply", Z1, note="Source statuses (Expired / Locked); normalised buckets need procurement sign-off.")
ov(78, "live", "Supply", Z1, note="POs, ordered qty and value by month.")
ov(79, "partial", "Supply", Z1, needs="Committed delivery date definition", note="Days from PO delivery date to first receipt shown; not labelled on-time until confirmed.")
ov(80, "live", "Supply", Z1, note="Ordered, shipped (ASN), received and open quantity per SKU and PO.")
ov(82, "partial", "Supply", Z1, needs="Open POs + on-time definition", note="Lead time, fill rate and PO value shown; on-time and open PO value not.")
ov(83, "partial", "Supply", Z1, needs="Overdue quantity", note="Ordered, received, open qty, fill rate and supplier count per SKU.")
ov(84, "live", "Supply", Z1, note="Received qty x landing cost.")
# invoices / finance
ov(13, "partial", "Finance", Z1, needs="Due dates (overdue)", note="Invoice total, pending, payments and mismatch shown; overdue not available.")
ov(85, "partial", "Finance", Z1, needs="Invoice line export", note="Invoice header amount plus shipped / received value from goods-receipt lines.")
ov(86, "live", "Finance", Z1, note="Debit notes by month and type (quantity shortfall vs brand-funded discount).")
ov(87, "live", "Finance", Z1, note="Distinct invoice headers, no line join.")
ov(88, "partial", "Finance", Z1, needs="Per-invoice payment allocation", note="Invoice - matched quantity debit note - payments matched by reference.")
ov(89, "feed", needs="Invoice due dates / payment terms")
ov(91, "live", "Finance", Z1, note="Invoice vs shipped (ASN) and vs received quantity at PO cost.")
ov(92, "live", "Finance", Z1, note="Invoice value by booking week.")
ov(93, "partial", "Finance", Z1, needs="Due dates (overdue)", note="Paid and pending shown; overdue not available.")
ov(94, "feed", needs="A second marketplace", note="All invoices are Zepto.")
ov(95, "live", "Finance", Z1, note="Ageing by invoice age (labelled), not days overdue.")
ov(96, "partial", "Finance", Z1, needs="Dispute status", note="Invoice, PO, amounts, debit note and pending shown; dispute status not available.")
# ads
ov(14, "live", "Ads", Z1, note="ROAS and ACOS from the Zepto ad-console export (all pages).")
ov(18, "partial", "Ads", Z1, needs="Campaign-level export", note="ROAS, CTR, CPC and conversion by ad page; the export has no campaigns.")
ov(121, "live", "Ads", Z1, note="Spend from the ad-console export by page.")
ov(122, "live", "Ads", Z1, note="Revenue attributed by the ad console, by page.")
ov(123, "live", "Ads", Z1, note="Attributed sales / spend; shown as — when spend is 0.")
ov(124, "live", "Ads", Z1)
ov(125, "live", "Ads", Z1)
ov(126, "live", "Ads", Z1, note="Clicks / impressions, recomputed from additive columns.")
ov(127, "live", "Ads", Z1, note="Spend / clicks, recomputed from additive columns.")
ov(128, "live", "Ads", Z1, note="Conversion = orders / clicks (event: order).")
ov(129, "partial", "Ads", Z1, needs="Attributed sales by day", note="Daily ad-wallet spend shown; the export has no daily attributed sales.")
ov(130, "feed", needs="Dated ad export", note="The Zepto ad export has no dates.")
ov(131, "partial", "Ads", Z1, needs="Dated ad export", note="Totals and CTR shown; no time trend.")
ov(132, "live", "Ads", Z1, note="CTR and conversion by ad page at the same grain.")
ov(133, "partial", "Ads", Z1, needs="Blinkit ad export", note="Zepto only; Blinkit ad data was removed.")
ov(134, "feed", needs="Campaign-level export")
ov(135, "feed", needs="Campaign / keyword-level export + thresholds")
ov(136, "feed", needs="Campaign-level export")
for _n in (144, 148, 152, 153):
    ov(_n, "feed", needs="Keyword-level ad export", note="The keyword ad data was removed; Zepto's export has no keywords.")
ov(149, "proxy", "Visibility", "B+Z scraped", needs="Search impressions", note="Share of shelf / rank proxy only; the keyword ad impressions were removed.")

SEC_OF = {}
_bounds = [(1, 22, 1), (23, 30, 2), (31, 41, 3), (42, 51, 4), (52, 67, 5), (68, 83, 6), (84, 96, 7), (97, 120, 8),
           (121, 136, 9), (137, 141, 10), (142, 156, 11), (157, 167, 12), (168, 171, 13)]
for lo, hi, s in _bounds:
    for k in range(lo, hi + 1):
        SEC_OF[k] = s
for _m in M:
    if _m["dep"] == "dash_013":
        _m["dep"] = ""
M.sort(key=lambda x: x["n"])
assert [m["n"] for m in M] == list(range(1, 172)), "every metric 1..171 exactly once"
for m in M:
    m["sec"] = SEC_OF[m["n"]]

LABEL = {"live": "Visible", "proxy": "Visible (proxy)", "partial": "Partly visible", "feed": "Not visible"}


def build():
    meta = dict(generated=TODAY, total=len(M), sections=SECTIONS,
                counts=dict(Counter(m["status"] for m in M)))
    (ROOT / "portal" / "src" / "lib" / "metricCoverage.json").write_text(
        json.dumps(dict(meta=meta, metrics=M), indent=1, ensure_ascii=False) + "\n", encoding="utf-8")

    c = meta["counts"]
    out = [f"# Metric coverage - {TODAY}", "",
           "Which of the 171 handbook metrics (Quick-Commerce Metric Formula Dictionary) are visible in the portal, which are not, and what unblocks each.",
           "Generated by `scripts/metric_coverage.py`; the live version is the portal page **/metrics**.", "",
           "## Read this first",
           "- **Applied 2026-11-13:** `silver_075` + `silver_076` (the scraper schema dropped `platform_listings.brand / name / pack_size / image_url`, so every silver run had failed since 2026-11-11), `dash_013` (competitor tables) and `dash_014` (cron job re-registered). "
           "The pipeline has been healthy since run 1681 (07:00-07:02 UTC); Overview / Availability / Pricing / Visibility and the competitor pages are current for Blinkit and Zepto.",
           "- Competitor figures cover Blinkit \"Frozen Veg Snacks\" and Zepto \"Veg Snacks\" (categories where a client brand is listed). Share of shelf is a proxy for share of voice / market share. Zepto first-party exports (sales, stock, PO, GRN, invoices, payments, ledger, ad console) are loaded in dash.fp_* and shown on the Sales, Supply, Finance and Ads pages. The Blinkit ad exports were removed from the database on request, so keyword- and campaign-level ad metrics are not available until a keyword-level export is loaded.",
           "- Status is about what is wired to a portal page, not what is theoretically possible. `Visible (proxy)` means shown and labelled as a proxy, as the handbook allows.",
           "- Core rule of the handbook applies: no sales, GMV, inventory, ads or finance number is ever estimated from scraped prices; those rows say *Not available*.", "",
           "## Totals", "", "| Status | Metrics |", "|---|---|"]
    for k in ("live", "proxy", "partial", "feed"):
        out.append(f"| {LABEL[k]} | {c.get(k, 0)} |")
    out += [f"| **Total** | **{len(M)}** |", "", "## By section", "",
            "| Section | Visible | Proxy | Partly | Not visible |", "|---|---|---|---|---|"]
    for s, name in SECTIONS.items():
        cs = Counter(m["status"] for m in M if m["sec"] == s)
        out.append(f"| {s}. {name} | {cs.get('live', 0)} | {cs.get('proxy', 0)} | {cs.get('partial', 0)} | {cs.get('feed', 0)} |")

    # what unblocks what
    need = defaultdict(list)
    for m in M:
        if m["status"] in ("feed", "partial") and m["needs"]:
            need[m["needs"]].append(m["n"])
    out += ["", "## What unblocks the not-visible metrics", "", "| Needed | Metrics unblocked (numbers) | Count |", "|---|---|---|"]
    for k, v in sorted(need.items(), key=lambda kv: -len(kv[1])):
        out.append(f"| {k} | {', '.join(map(str, v))} | {len(v)} |")

    for s, name in SECTIONS.items():
        out += ["", f"## {s}. {name}", "", "| # | Metric | Status | Where | Platforms | Needs applied / missing | Note |", "|---|---|---|---|---|---|---|"]
        for m in (x for x in M if x["sec"] == s):
            tag = m["dep"] and f"apply {m['dep']}" or ""
            need_txt = "; ".join(t for t in (tag, m["needs"]) if t)
            out.append(f"| {m['n']} | {m['name']} | {LABEL[m['status']]} | {m['page'] or '-'} | {m['plat'] or '-'} | {need_txt or '-'} | {m['note'] or ''} |")
    path = ROOT / "docs" / f"METRIC_COVERAGE_{TODAY}.md"
    path.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(f"{len(M)} metrics: " + ", ".join(f"{LABEL[k]} {c.get(k, 0)}" for k in ("live", "proxy", "partial", "feed")))
    print("wrote", path.relative_to(ROOT), "and portal/src/lib/metricCoverage.json")


if __name__ == "__main__":
    build()
