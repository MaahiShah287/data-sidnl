# Metric status vocabulary

Every entry in `metrics/metric_dictionary.yaml` carries a `status` field. The
status controls how the chatbot is allowed to answer a question about that
metric.

| Status | Meaning | What the bot does |
|---|---|---|
| `approved` | Definition signed off by the analytics owner; safe to quote as the company definition. | Answers normally. No status banner. |
| `gold` | Computed by the Gold (`dash`) pipeline; the authoritative formula is in `dash.metric_catalog`. | Answers normally, says the value comes from the Gold layer. No draft banner. |
| `draft` | A definition has been written and is used for now, but it is **not signed off** and may change. | Answers, but prefixes the answer with `⚠️ Draft definition:` (RAG) or `⚠️ Draft metric:` (SQL) and repeats the definition verbatim so the caveat is visible. |
| `unsupported` | The data needed is not in Silver or Gold. | Refuses to produce a number. For SQL the planner returns `{"error": "unsupported metric: <name>"}` instead of generating SQL. |

## Two layers

`metrics/metric_dictionary.yaml` entries carry a `layer` field:

- **`silver`** — raw, quality-filtered SKU × store readings (price, stock,
  shelf position). Six metrics, all `draft` until the analytics owner signs off.
- **`gold`** — dashboard KPIs from the `dash` schema: OSA, listing, stockouts,
  DOI, price parity, share of shelf (SOH), share of voice (SOV), rank, GMV,
  units, ASP, growth, ad spend/ROAS, fill rate, PO and invoice value,
  serviceability, freshness.

`dash.metric_catalog` is the authoritative Gold list (57 metrics with formula,
status and source columns). The dictionary gives exact SQL templates for the
Gold metrics the chatbot can answer directly.

## Current state of the dictionary (2026-11-14)

- **`gold`:** every Gold KPI listed above (OSA, listing, SOH, SOV, GMV, ROAS,
  fill rate, …). These are answerable; they are **not** unsupported.
- **`draft` (6 Silver + 1 Gold):** `observed_in_stock_rate`,
  `observed_oos_rate`, `avg_discount_pct`, `current_price`,
  `ad_placement_rate`, `avg_organic_position`, plus Gold
  `potential_sales_loss` (a modelled estimate, always labelled as such).
- **`unsupported` (4):** `delivery_eta`, `instamart`, `jiomart`,
  `industry_market_share`.

## Why it matters

A `draft` metric is still answerable — the caveat is the point. An
`unsupported` metric must never be estimated from a proxy column: for example
`sales` cannot be derived from `mrp` or `sale_price` in Silver, but it **is**
available as first-party GMV in Gold. Refusing a Gold KPI as "unsupported" is
now a bug; refusing delivery ETA, Instamart, JioMart or industry market share
is still correct.

Open definition questions live in `OPEN_QUESTIONS.md`; the biggest one is
whether NULL `availability` rows belong in the denominator of
`observed_in_stock_rate`.
