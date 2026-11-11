# Metric status vocabulary

Every entry in `metrics/metric_dictionary.yaml` carries a `status` field. The
status controls how the chatbot is allowed to answer a question about that
metric.

| Status | Meaning | What the bot does |
|---|---|---|
| `approved` | Definition signed off by the analytics owner; safe to quote as the company definition. | Answers normally. No status banner. |
| `draft` | A definition has been written and is used for now, but it is **not signed off** and may change. | Answers, but prefixes the answer with `⚠️ Draft definition:` (RAG) or `⚠️ Draft metric:` (SQL) and repeats the definition verbatim so the caveat is visible. |
| `unsupported` | There is no agreed definition, or the data needed is not in the silver layer. | Refuses to produce a number. For RAG it says the metric is not yet defined; for SQL the planner returns `{"error": "unsupported metric: <name>"}` instead of generating SQL. |

## Current state of the dictionary (2026-11-11)

- **`draft` (6):** `observed_in_stock_rate`, `observed_oos_rate`,
  `avg_discount_pct`, `current_price`, `ad_placement_rate`,
  `avg_organic_position`.
- **`unsupported` (10):** `cross_platform_price_gap`, `SOV`, `SOH`, `sales`,
  `revenue`, `ad_spend`, `ROAS`, `conversion`, `clicks`, `impressions`.
- **`approved`:** none yet. No metric has been signed off, so every numeric
  answer currently carries a draft banner. This is expected, not a bug.

## Why it matters

A `draft` metric is still answerable — the caveat is the point. An
`unsupported` metric must never be estimated from a proxy column: for example
`sales` cannot be derived from `mrp` or `sale_price`, and `SOV`/`SOH` have no
agreed company formula. Refusing is the correct behaviour and is scored as a
pass in the evaluation (`expect_no_data`).

Open definition questions live in `OPEN_QUESTIONS.md`; the biggest one is
whether NULL `availability` rows belong in the denominator of
`observed_in_stock_rate`.
