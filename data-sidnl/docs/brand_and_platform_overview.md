# Brand and platform overview

This page explains who the primary brand is, which competitor is used as a
shelf-position benchmark, and what SIDNL is. It is the reference for
"what is ...?" questions; metric formulas live in
`metrics/metric_dictionary.yaml` and `metrics/gold_layer.md`.

## SIDNL

SIDNL is a quick-commerce analytics and AI intelligence platform. It observes
the online shelf on Indian quick-commerce platforms and turns those readings
into comparable metrics: availability / OSA, listing rate, stock-outs, price
and discount, price parity, share of shelf (SOH), share of voice (SOV), shelf
rank, and first-party sales, ads and finance KPIs.

The data flows through two layers:

- **Silver** - raw, quality-filtered SKU x store readings: price, MRP,
  discount, availability, stock, shelf position, search rank. Silver is the
  source of truth for "what did we see at this store".
- **Gold (`dash`)** - pre-aggregated dashboard tables and views built from
  Silver: OSA, listing, stock-outs, DOI, price parity, SOH, SOV, shelf rank,
  GMV / units / ASP / growth, ad spend / ROAS / ACOS, fill rate, PO and invoice
  value, serviceability and freshness.

Coverage today is Blinkit and Zepto across 11 cities: Ahmedabad, Bengaluru,
Chennai, Delhi, Gurugram, Hyderabad, Kolkata, Mumbai, Navi Mumbai, Pune and
Thane. SIDNL is the analytics platform, not a retailer or a brand: it does not
sell products. It measures brands that are sold on those platforms.

The chatbot in this repository answers two kinds of questions over that data:
numeric questions (SQL over Silver or Gold) and definition questions
(documentation like this page).

## Mr. Munchies (primary brand)

Mr. Munchies is the primary quick-commerce brand tracked by SIDNL (the client
brand). It is a frozen-food / frozen-snacks brand sold on Blinkit and Zepto.

- Platforms: Blinkit and Zepto.
- Cities: the same 11 cities listed above.
- Latest product-page observation at the time of writing: 2026-11-13.
- 14 distinct product names in the latest product-page view.

Category placement in the database:

| Platform | L1 category | L2 category |
|---|---|---|
| Blinkit | Instant & Frozen Food | Frozen Veg Snacks |
| Zepto | Frozen Food | Veg Snacks |

The product range is built around frozen snacks and soya chaap:

- Soya chaap: Afghani, Lasooni and Tandoori.
- Rolls and samosas: Veg Spring Roll, Pizza Samosa, Cheese Chilli Samosa.
- Burger patties: Cheese Burst Veg Burger Patty, Spicy Paneer Burger Patty.
- Other snacks: Cheese Jalapeno Poppers / Cheese Nuggets, Spicy Frozen Paneer
  Bites.

Packs are typically 250-280 g. Mr. Munchies is also read from the category
shelf (share of shelf, rank, paid and organic position), not only from its own
product pages.

## Amul (competitor benchmark)

Amul is not a client brand. It is the main competitor benchmark tracked on the
category shelf, used for shelf-position comparisons (share of shelf, rank,
price gaps) where it appears on the same shelf as Mr. Munchies.

- Source: shelf-position readings (`silver.v_latest_shelf_position`), on
  Blinkit and Zepto, across the same 11 cities.
- The Amul family in the data includes Amul, Amul Gold, Amul Tru, Amul Kool,
  Amul Kool Cafe, Amulspray, Amulya and Amul Pro. Mother Dairy appears in a
  small number of shelf rows.
- Amul's shelf presence spans Sweet Tooth > Chocolates, Sweet Tooth > Indian
  Sweets, Instant & Frozen Food > Frozen Veg Snacks and Frozen Food > Veg
  Snacks. The frozen-snacks overlap is what makes it a valid shelf benchmark
  for Mr. Munchies.

Only Amul's shelf position is tracked. Its product-page price and stock are not
part of `silver.v_latest_observation`, so "Amul price" questions must use the
shelf / competitor data rather than the client-brand observation view.

## Data coverage notes (verified 2026-11-15)

These counts describe what the chatbot can actually see; they are not targets.

- `silver.v_latest_observation` (latest product-page reading per listing and
  store) contains Mr. Munchies only: 8,101 rows, 14 distinct product names,
  Blinkit and Zepto, 11 cities.
- `silver.v_latest_shelf_position` contains all brands on the tracked category
  shelves: the Amul family has about 150,000 rows, Mr. Munchies about 3,900
  rows, plus a small Mother Dairy presence.
- `silver.v_all_platforms` spans both platforms: Blinkit about 201,500 rows and
  Zepto about 9,900 rows.
- The Gold dimension tables `dash.dim_brand`, `dash.dim_category`,
  `dash.dim_platform`, `dash.dim_product` and `dash.brand_registry` are empty
  in the current database. Use the Silver `brand`, `l1_category` /
  `l2_category` and `platform` columns for names.
- Genuinely unavailable: Instamart and JioMart (no rows), delivery ETA (not
  populated), and industry market share / total category size (no input).
