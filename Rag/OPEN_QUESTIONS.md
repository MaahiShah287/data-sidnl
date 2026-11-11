# OPEN_QUESTIONS.md

Items requiring confirmation before code or metric definitions can be finalised.
Add results from diagnostics here.

## SQL Views (sql/01_views.sql)

- [OPEN] Valid values for `scrape_status` and `scrape_run_status` → needed to fill TODO(diagnostics) stubs in 01_views.sql. Run sql/02_diagnostics.sql Block 1 against Supabase.
- [OPEN] Is `listing_id` guaranteed non-null for all four platforms? The views fall back to `platform_product_id`. Owner: scraping team.
- [OPEN] Is `scrape_run_id` monotonically increasing globally (not just per scraper)? If per-scraper only, partition v_latest_shelf_position ORDER BY by scrape_backend too. Owner: data-engineering lead.

## Metrics

- [OPEN] `observed_in_stock_rate`: Should NULL `availability` rows be excluded from denominator (current draft) or treated as a separate "unknown" bucket? Owner: analytics mentor.
- [OPEN] `avg_discount_pct`: Simple average vs weighted (by listing count or inventory)? Owner: analytics mentor.
- [OPEN] `ad_placement_rate`: Are observation rows with `is_ad` populated valid ad signals, or should ad metrics use shelf_position rows exclusively? Owner: data-engineering lead + analytics mentor.

## Data Quality (pending Stage A profiler run)

- [OPEN] Are there rows where both source_type=observation AND source_type=shelf_position exist for the same (platform, listing_id, store_id)? Run Block 3 of sql/02_diagnostics.sql.
- [OPEN] What is the NULL rate on `availability` per platform? If > 20%, flag as a data-quality issue.

## Metric Definitions Pending

- [OPEN] SOV (Share of Voice): company definition not yet agreed. Status: unsupported.
- [OPEN] SOH (Share of Shelf): company definition not yet agreed. Status: unsupported.

## Stage A (profile_data.py)

- [OPEN] DATABASE_URL not configured — profiler script has not been run. 
  To run: (1) copy .env.example to .env, (2) fill in DATABASE_URL with sidnl_chatbot_ro credentials, (3) run: python scripts/profile_data.py
  Results must be pasted here before the view TODOs can be filled.

## Evaluation (run_ground_truth.py, 2026-11-10)

Full audit: **`reports/eval_feasibility.md`** (generated from the live views).

### The real data is far narrower than the question set assumes

- **`v_latest_observation`** (price, discount, stock, ETA): **Blinkit only**,
  **brand = `Mr. Munchies` only**, 5,055 rows, 11 cities.
- **`v_latest_shelf_position`** (position, ads): Blinkit — Amul 31,401,
  Mr. Munchies 2,583, Mother Dairy 7 — plus **Zepto × Mumbai × Amul, 344 rows
  only**.
- **No Instamart or JioMart rows anywhere.** Only two categories:
  `Instant & Frozen Food`, `Sweet Tooth`.

### Consequence: 21 of 25 numeric questions cannot be answered

| Verdict | Count | IDs |
|---|---|---|
| Answerable | 2 | N10, N18 |
| Degraded (answerable, but not as asked) | 2 | N04 (top-10, only 2 brands exist), N25 (brand cardinality is 3) |
| **Not answerable** | **21** | N01–N03, N05–N09, N11–N17, N19–N24 |

The earlier note ("12 questions return 0 rows") understated it: some return a
row only because their ground-truth SQL silently substitutes a different
platform/city/brand than the question asks. The **ground-truth SQL is wrong for
18 of 25** questions — e.g. N02 asks *Zepto/Mumbai/Haldiram* but the SQL filters
`platform='blinkit' AND brand='Mr. Munchies'`; N20 asks *Zepto/Bangalore* but
the SQL uses `city='Mumbai'`. Their `ground_truth_value` is therefore a number
for a different question.

- [DECISION NEEDED] How to make the baseline valid. Options:
  1. **Rewrite** the 21 unanswerable questions against real data
     (Blinkit/Mr. Munchies for price/stock; Blinkit+Zepto/Amul/Mr. Munchies for
     position/ads; the 11 cities that exist). Best numeric-accuracy signal.
  2. **Mark them `expect_no_data: true`** and score "correctly reports no
     data" as a pass. Keeps them as hallucination/coverage tests; few accuracy
     tests remain (2–4).
  3. **Both**: keep ~8 as `expect_no_data` honesty tests, rewrite the rest, and
     add ~10 new answerable questions.
  Do NOT change this silently — it moves the baseline.
- [RESOLVED 2026-11-11] **Option 3 chosen (user-approved).**
  `eval/questions.jsonl` now has 75 questions: 37 NUMERIC (25 slots + N26–N35
  new answerable), 8 `expect_no_data` honesty tests, 27 answerable overall,
  38 non-numeric. Every SQL-bearing question has an explicit `primary_column`
  so `run_ground_truth.py` stops reporting `listing_count` instead of the
  metric. All 35 SQL questions execute; the 8 coverage gaps return 0 rows.
  `eval/run_eval.py` scores `no_data_correct`. See
  `RAG_PIPELINE_DOCUMENTATION.md` §10 for the full rationale.
- [FACT] `N16` = 1 and `N20` = 86.6 are numbers for **Mumbai**, not the cities
  the questions name; they must be discarded, not "verified".

