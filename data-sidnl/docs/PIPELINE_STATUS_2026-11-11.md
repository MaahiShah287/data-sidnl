# SIDNL pipeline status, 2026-11-11

Today's work: bring silver in line with *Bronze → Silver: which columns to carry* (10 Nov), cut the silver
self-tests down to a lean suite, and harden fallbacks, data quality and performance.

**Status: applied to production on 2026-11-11 06:36–06:40 UTC** (`silver_069`, `silver_070`, `dash_011`, `silver_071`, `silver_072`, then `silver_073` at 07:03; each md5 equals its file in `sql/migrations/`). Backfill done (99,251 shelf rows, 48,879 readings, 4,777 scans); self-test 35/35; `sidnl-context` ran on its own at 06:40 (2.6 s, 9/9 sections). Before applying, all five were executed against production (Supabase, at `silver_068`) inside transactions that were rolled back. Afterwards the
database was confirmed unchanged: same latest migration, no new objects, `refresh_brand` byte-identical. The real
code ran on real rows (loaders, backfill, context load, dash refresh, self-test, gate).

## 0a. After applying (production, measured)

| Check | Result |
|---|---|
| md5 of each applied migration vs its file in `sql/migrations/` | 5/5 identical (also checked by `tests/test_offline.py`) |
| Self-test suite `silver.selftest()` | **35/35** |
| `sidnl-context` cron, first run on its own (06:40 UTC) | succeeded, 2.6 s, 9/9 sections; re-run changed 0 rows |
| Forced full reload through the job queue (job 5732, run 800) | **success**, 18 gate checks, 0 blocking, 0 rejected; gold rebuilt in 46.9 s |
| Out-of-stock rows from failed or incomplete reads | 0 |
| Valid rows the dashboard uses | shelf 1,992,169; readings 55,005 |

**New bottleneck found while verifying.** That full reload took **509 s** (last full reload before today: 345 s on a
14 % smaller table), against cron's 600 s limit; the nightly 18:35 UTC run takes the same path. Cause: the per-row
quality functions (`reading_dq`, `dq_status`, `map_stock_status` and today's `read_flags`, `read_stock_status`,
`safe_int`) carry `SET search_path`, which stops PostgreSQL from inlining them, so every one of 2.09 M rows pays several
full function calls (`reading_dq` alone: 34 s over the table). Fix written as `sql/pending/silver_073_inline_row_functions.sql`
(drops the clause; they only call built-ins). Measured in a rolled-back test: **4.51 s → 1.49 s per 100,000 rows**,
about a minute off every full reload. **Applied 07:03 UTC** (md5 matches, self-test 35/35); measured after: 1.56 s per 100,000 rows. `reading_dq` alone only improves 34.3 s -> 28.6 s over the table: PostgreSQL still won't fully inline it because it uses each argument several times; rewriting it is a later step.

## 0. Dry-run results (2026-11-11, measured)

| What | Result |
|---|---|
| **Quality gate per pipeline run** (`silver_072`) | **4.23 s → 0.10 s** (best of 3, about 42× faster); the same 18 checks with identical violations and block decisions |
| Category-shelf loader on a real incomplete read (snapshot 5990) | 315/315 rows flagged `read_incomplete`, 0 out-of-stock left, 0.54 s |
| Brand loader (amul, incremental) / category-market loader | both run cleanly: 344 readings + 30 scans updated, no failed scopes |
| Backfill `silver.backfill_read_flags()` | 27.9 s, one pass: 98,936 shelf rows + 48,535 readings + 4,777 store scans |
| Rule "no out-of-stock from a failed or incomplete read" | 5,433 violating rows before → **0 after**; the check takes 0.042 s (partial index) |
| Context loader (`silver_070`), first run | 1.2 s, 9/9 sections ok: 8,116 shelf reads, 655 runs, 24,236 check points, 8,900 coverage rows, 5,125 probes, 4,820 sample points, 24 listings, 21 catalog products, 7,180/7,180 products linked to bronze ids |
| Context loader, second run | 0.47 s, **0 rows changed** (idempotent) |
| Dash context refresh (`dash_011`) | 0.27 s, 111 coverage rows, 27 collection-health rows; the run buckets always add up |
| Self-test suite (`silver_071`) | 35 tests; 34 pass before the backfill (the 35th is the rule above, which passes after it) |

**Effect on the dashboard** (rows leaving the metrics because they come from incomplete reads):

| Fact | Valid before | Valid after | Change |
|---|---|---|---|
| shelf positions (share of shelf, ranks) | 2,091,420 | 1,992,169 | −99,251 (−4.7 %): 613 shelf reads with `complete = false` |
| brand-search readings | 8,058 | 7,427 | −631 (−7.8 %) |
| shelf readings (client brands) | 40,821 | 40,208 | −613 |
| stock checks | 7,370 | 7,370 | unchanged |

**What the dry run changed in the code:**
1. **Search reads that `stopped_early` count as finished.** 3,496 of 8,058 brand-search readings come from scans with
   `complete = false` *and* `stopped_early = true`, which is the scraper stopping on purpose. Treating those as
   incomplete would have dropped 43 % of keyword data. Only the 631 genuinely partial ones are flagged.
2. **Store-scan backfill added**: without it, 4,747 existing scans would never have received query/lat/lon/error.
3. **Partial index for the read rule**: the new self-test check first took 3.7 s (full scan of 2.09 M rows); now 0.04 s.
4. **Collection health uses the real status words** (`done` / `failed`, `blocked` / `partial`, `stopped`,
   `interrupted`): separate ok / partial / failed counts. Completion is capped per run, because check runs report
   more points done than planned (107.9 % before the fix).

**Found, no change needed:** `observations.details` (units cap, pack size, store role) exists on only 530 of 18,157
stock checks, all from non-client brands on 29–30 Oct, which silver does not load. The columns are wired and will
fill once the scraper writes `details` for client brands. `coverage` holds only serviceable pairs, so its
`serviceable_pct` is always 100 %; the informative serviceability rate comes from `check_point`.

To repeat the dry run locally: `python sidnl.py dry-run` (needs `SUPABASE_DB_URL`).

## 1. Column contract: what changed

| Doc says | Before | Now (pending) | Migration |
|---|---|---|---|
| observations: carry `details.max_allowed_quantity`, `pack_size`, `store_role` | not carried | `fact_product_reading.max_allowed_quantity`, `pack_size_seen`, `store_role` | silver_069 |
| search_cards: carry `matched_by`, `variant_of` | not carried | `fact_product_reading.matched_by`, `variant_of` | silver_069 |
| search_snapshots: carry `query`, `lat`, `lon`, `error`, `city_slug`; leave `pages_read` | `pages_read` carried; the others missing | `fact_store_scan.search_query`, `latitude`, `longitude`, `scan_error`; city falls back to the snapshot's city; **`pages_read` removed** | silver_069 |
| **Failed or incomplete read must not produce `out_of_stock`** | failed search reads and `complete = false` shelf reads produced out-of-stock rows that dash counted | row kept; out_of_stock becomes `unknown`; flag `read_failed` (invalid) / `read_incomplete` (suspect), so it is out of every dash metric. Knob: `sidnl_config.exclude_incomplete_reads` | silver_069 |
| cities: `center_lat` / `center_lon` only if the front end reads them from gold | carried; dash and the portal never read them | **removed** from `silver.dim_city` | silver_069 |
| stores: carry all bronze columns | plus a stray `"store_weight (weight per store, e.g. store sales)"` column, never written or read | **removed** | silver_069 |
| shelf_snapshots: one row per read (sweep_id, category_name, status, error, lat/lon, complete…) | only `status = 'ok'` reads, and only as columns copied onto each shelf row | `silver.fact_shelf_snapshot`, every status, with `read_ok` | silver_070 |
| category_sweeps, brand_scrapes, check_runs, product_lookups: run records | not in silver | `silver.fact_scrape_run`, one shape with a `job_type` column; replaces `analytics.scraping_jobs` as the run table and adds `blocked` / `errors` | silver_070 |
| check_points, coverage, fulfilment_probes: "not delivered here" ≠ "out of stock" | not in silver | `silver.fact_serviceability` (`location_verified = false` is suspect) | silver_070 |
| sample_points | not in silver | `silver.dim_sample_point` | silver_070 |
| platform_listings incl. `details.brand_id / variant_id / category / subcategory / l3_category_ids`, price, mrp, created_at | partly, through `dim_product` | `silver.dim_listing` | silver_070 |
| products: `org_id`, `name_source` (each brand sees only its own) | `org_id` missing | `silver.dim_catalog_product` | silver_070 |
| platform_products: `id` | missing | `dim_product.source_product_id` | silver_070 |
| → gold (dash) | none of the above | `dash.coverage` (serviceable points, with numerator and denominator), `dash.collection_health` (runs, failed runs, store completion, blocked, shelf reads that worked) | dash_011 |
| Never copy `demo_requests`, app tables, `listing_snapshots`, `brand_logos`, `fetch_runs`, `platform_state` | not copied | still not copied; the self-test now fails if anything in silver / dash / ops / analytics reads `demo_requests` | silver_071 |

Deliberately **not** done, with the reason:
- **Renaming to the doc's names** (`inventory_units` → `units`, `inventory_is_capped` → `units_is_minimum`, source types `shelf`/`search`). The Rag views (`v_latest_observation`, `blinkit` …) and dash read the current names, and they must not be renamed (ARCHITECTURE §2). The mapping is documented instead.
- **fetch_attempts per-run totals** (attempts, failed, blocked, bytes_in by backend/vendor, for the Decodo budget). The doc does not name the columns that link an attempt to a run or mark it as blocked. Building it without seeing those columns would mean guessing. It needs a 5-minute look at the bronze table first (roadmap P1).
- **Bronze `id` for check_points and coverage**: the doc lists `id` under "leave". Silver keeps it as `source_record_id` anyway, because it is the dedupe key and the only trace back to bronze (the doc's own rule for observations).

## 2. Test suite: ~85 checks down to 35 named tests, no input dropped

| Before | After (silver_071) |
|---|---|
| `selftest_parser()`: 61 one-line asserts that stop at the **first** failure and only print its name | `silver.selftest()`: 35 behaviours (e.g. "parse_pack: multipacks give size x count"). All 61 bronze input strings are still checked, grouped by behaviour. Each failing test lists **every** failing input with got/expected |
| `selftest_matcher()` (9), `quality_checks()` (re-runs both + 4 integrity checks) | the same checks, called once |
| Python: 11 live tests, 5 of them re-running the database suites | 7 live tests (1 suite call + the fault-injection scenarios: gold failure, stale scraper, heartbeat) + **11 new offline tests** that run without a database |
| missing: the failed-read rule, the personal-data guard | added: "no out_of_stock row from a failed or incomplete read" on real data, "nothing reads demo_requests", "every sidnl-* job active" |

The offline tests (`tests/test_offline.py`, all passing) tie the doc's column list to the migrations: every carried
column must have a silver column, nothing marked "leave" may be loaded, never-copy tables are never selected. They also
check that every migration has a rollback, checks bronze columns before changing anything and parses as PostgreSQL,
plus the CLI's connection retry. `selftest_parser()` keeps its contract because the quality gate calls it.

## 3. Robustness: fallbacks, retries, data quality, logging

| Mechanism | Where |
|---|---|
| **Preflight**: each migration first checks that every bronze column it reads exists, and stops with the full list of missing columns before changing anything | silver_069, silver_070 |
| **Isolation**: the new context loader runs 9 sections, each in its own savepoint. A failing section is logged (`ops.etl_run`, `brand_key = '_context'`, with error class) and the rest still load. It runs on its own cron job (`sidnl-context`, every 10 min, advisory lock 727102), so it can never block or slow the main pipeline or the main gold refresh | silver_070, dash_011 |
| **Type-safe parsing** of bronze JSON and counters (`silver.safe_int`): a junk value becomes NULL instead of failing the whole brand load | silver_069 |
| **Missing data**: shelf/search city falls back to the snapshot's city when the store has none (only known cities, flagged `info_city_from_snapshot`). Missing serviceability flag → invalid; unverified location → suspect | silver_069, silver_070 |
| **Duplicates / reruns**: every new load is an idempotent upsert on the bronze id, with `IS DISTINCT FROM` guards (no rewrite when nothing changed) and a lookback window for late status updates | silver_070 |
| **Knobs as fallbacks**: `exclude_incomplete_reads` (0 = only flag), `dq_gate_window` (0 = old full-table gate) | silver_069, silver_072 |
| **Retries in the CLI**: `connect()` retries transient connection errors after 2, 4 and 8 s, gives up at once on a bad password, and logs each retry | sidnl.py |
| **Backfill** for rows loaded before the change: `select silver.backfill_read_flags();` is idempotent and batched | silver_069 |
| **Rollbacks** for all five migrations, newest first, with the exact previous function text | `sql/pending/rollbacks_pending.sql` |
| Existing and unchanged: job queue with 2/4/8/16-minute retries and permanent-error classes, dead letters with bisection, gold savepoint + backoff, freshness alerts, daily reconciliation, alert outbox, heartbeat | live since silver_036–068 |

## 4. Performance

| Change | Effect (measured in the dry run) | How to re-check |
|---|---|---|
| Quality gate (`dq_checks`, every pipeline run) grouped all ~1.8 M shelf rows on every run. Now the price and brand checks read only the processing window (through the unique index on `source_record_id`). The blocking product/store link checks still cover all rows, through two new small partial indexes | **4.23 s → 0.10 s per run**, same verdicts; the cost now follows the rows a run loaded, not the table size | `sidnl.py dry-run` prints `dq_checks` time before/after (best of 3) |
| Context tables refreshed every 10 min in their own job, not inside the ~40 s `dash.refresh()` | main gold refresh time unchanged | `ops.v_cron_health` |
| New columns are nullable without defaults (catalog-only change, no table rewrite of the 1.8 M-row table) | migration takes seconds; two short index builds block shelf writes briefly | dry-run prints time per file |

## 5. Current bottlenecks (known today)

1. **Full dash rebuild every successful run (~40 s)**, because SI ids are renumbered A-Z (36 of 54 runs on 10 Nov, up to 7,108 ids) and dash is keyed by `sidnl_id`. The SI-id logic must not change, so the fix is a stable surrogate key in dash with `sidnl_id` as an attribute. That allows an incremental refresh.
2. **`fact_shelf_position` is the size driver** (~1.8 M rows from 1.59 M bronze shelf rows) and grows with every sweep. Retention or partitioning by `obs_date` is not in place.
3. **Upstream data gaps, not pipeline faults**: Instamart and JioMart have no bronze rows; Zepto stock checks stopped 2026-10-30; category shelves exist for Blinkit only.
4. **Coverage limits**: 10,787 stock checks of non-client brands are outside `brand_scope`; OSA exists for Mr Munchies only.
5. **Human queues**: ~40 fuzzy matches wait for review; `auto_merge_fuzzy` stays 0 on purpose.
6. **Alerting reaches nobody yet**: Slack delivery (Gap 4) and the external heartbeat (Gap 5) are built but off until the owner adds the secrets.
7. **`Rag/` still queries `silver.demo`**, dropped in `silver_054`.

## 6. Roadmap to production readiness

**P0: apply today's work (owner, ~30 min)**
1. Decide the one open question from the dry run: should the 99,251 shelf rows (4.7 %) from 613 incomplete shelf reads leave the metrics (`exclude_incomplete_reads` = 1, the doc's rule, the default) or only be flagged (0)?
2. Apply in `sql/pending/ORDER` order with Supabase `apply_migration`, check each md5, then `select silver.backfill_read_flags();` until `shelf_done = true`.
3. Move the rollback blocks into `sql/rollbacks.sql`, then `python sidnl.py export-schema && python sidnl.py verify`, `python sidnl.py test`, commit.
4. Switch on Gap 4 (Slack) and Gap 5 (uptime monitor). These are the only owner-only steps.

**P1: this week**
- fetch_attempts → per-run totals (attempts, failed, blocked, bytes_in by backend/vendor) for the Decodo budget, after a look at the bronze columns.
- Decide "silver replaces or sits under `analytics.*` views" (one version of the truth). Today's tables make silver the superset.
- Expose the new facts to the backend through stable views (`silver.v_shelf_read`, `silver.v_serviceability`) with grants, rather than through the raw tables.
- Fix `Rag/` (`silver.demo`).

**P2: scale**
- Stable surrogate key in dash → incremental gold refresh (removes bottleneck 1).
- Partition / retention for `fact_shelf_position` and `fact_serviceability` by `obs_date`.
- CI: run `tests/test_offline.py` on every push, and the live suite nightly against a Supabase branch.
- Load the non-client stock checks once the brand onboarding rules allow it.
