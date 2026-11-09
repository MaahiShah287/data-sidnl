# Silver completion report — for review (Silver only; Gold not developed)

> Historical status report. Its scope predates Silver migrations 045–055 and
> Gold migrations 060–063. In particular, demo/view inventory and the statement
> below that Gold was not touched are not current-state descriptions. See
> [Silver operations](./SILVER_OPERATIONS.md) and
> [Gold metric views](../gold/GOLD_METRIC_VIEWS.md) for the later reported state.

**Status: SIGN-OFF NOT GRANTED YET. Three critical sign-off items remain unverified (Compute Disk allocation, real-repo commit, historical migration parity 000–003/005–009/024). Silver is NOT declared complete.**
Decision recorded 2026-11-08: Supabase Pro is active; no historical deletion, retention or archival is applied or planned for storage reasons. All shelf history is preserved.
Gold logic, tables, views and metrics were not touched. `gold.refresh_all()` still runs only from its own cron job (`sidnl-gold` → `silver.run_gold_pending()`).

## 1. Migrations (applied live, in order; each has a rollback file)
| Version | Name | Purpose |
|---|---|---|
| 20261107192120 | silver_036_quality_gate_watermark | quality gate, blocked scopes hold watermarks |
| 20261107192623 | silver_037_job_state_retry_isolation | job table, retry 2/4/8/16 min, category isolation, Gold decoupled |
| 20261107192925 | silver_038_deterministic_corrections | approved corrections |
| 20261107193239 | silver_039_storage_health_fk | brand FK, autovacuum, health views |
| 20261107194416 | silver_040_job_recheck_timing | fix from concurrency test |
| 20261107195949 | **silver_041_brand_loader_noop_guard** | **new** — brand loader only writes rows that changed |
| 20261107200119 | **silver_042_storage_alerts** | **new** — storage thresholds, projection, alert log (alert only) |
| 20261107201340 | silver_043_cron_health_view | read-only view of cron failures that bypass the job table (had a defect, fixed by 044) |
| 20261107202823 | **silver_044_cron_failure_alert** | **sign-off round** — counts only `failed` runs (running/starting are not failures); alert at >=3 consecutive failures; recovery log |
Existing SI ids, products and historical shelf rows were not changed in this round. Ledger and checksums: `sql_silver/MIGRATION_LEDGER.md`.

## 2. Item 1 — Brand loader no-op guard (041)
Before: every 2-minute run rewrote about 9,400 unchanged rows (run 209: 926 stores + 8 products + 3,017 scans + 5,453 readings).
Guard added to dim_city, dim_brand, dim_store, dim_product, fact_store_scan, fact_product_reading (`ON CONFLICT … WHERE (old cols) IS DISTINCT FROM (new cols)`); `updated` counters now mean real changes.
| Evidence | Result |
|---|---|
| Forced runs after 041 (mr munchies, mother dairy) | 0 updates, 0 inserts everywhere |
| Incremental brand runs, 10 runs before vs 12 after (SQL on `silver.etl_run`) | updates 46,138 → 134 (all 134 real store `last_seen_at` changes); inserts of new data unchanged (readings 335 → 459, scans 147 → 149) |
| Full reload twice | 0 / 0 for both brands |
| Injected 20 changed readings + 5 changed stores | reload corrected exactly 20 and exactly 5; second reload 0 |
Note: `loaded_at` / `etl_run_id` on these tables now mean "last time the row's data changed". Used only in `run_pipeline` and `v_wide` as informational. Run time did not change (brand steps were already ~3 s; most of the ~25 s run is the quality gate and canonical steps); the gain is no dead tuples / WAL from rewriting rows.
Rollback: `041_rollback.sql` (restores from `silver.function_backup`, tag `pre_041`).

## 3. Item 2 — Storage (042)
Pro quota and live usage are **not readable from the tools available to me**; `storage_plan_gb` is set to 8 (documented Pro baseline). **Please confirm the actual disk size in Dashboard › Settings › Compute and Disk** and update the setting if it differs.
| Measure (2026-11-07 20:xx UTC) | Value |
|---|---|
| Database size | 578 MB (silver 390 MB, public 189 MB, gold 7 MB) |
| WAL directory | 1.0 GB |
| Used (db + WAL) | 1.68 GB = 19.6 % of 8 GB → level `ok` |
| `silver.fact_shelf_position` | 374 MB for 570,136 rows (656 B/row incl. indexes) |
| Bronze `public.shelf_positions` | 140 MB (246 B/row); one scraped row costs about 902 B across bronze + silver |
| Growth (rows scraped, 14-day window, only 4 active days) | average 40,739 rows/day = 35 MB/day; peak day 305,442 rows = 263 MB/day |
| Projection to full 8 GB | about 188 days at the recent average; about 25 days if every day ran at the peak |
Scraping is uneven (rows/day: 238,353, 305,442, 222, 26,329), so only the range is meaningful. WAL is counted conservatively; if the dashboard excludes it, headroom is larger.
Alerts: warn at 70 %, critical at 85 % (config `storage_warn_pct`, `storage_crit_pct`); `silver.check_storage_alert()` runs on every tick, logs level changes in `silver.storage_alert_log`, repeats non-ok levels daily and raises a WARNING. Test (rolled back): forced thresholds produced `warning`, `critical`, then back to `ok` (3 log rows, then undone). Nothing is deleted, archived or partitioned.
Rollback: `042_rollback.sql` (additive objects only).

## 4. Item 3 — Git reconciliation
- 8 live-only migrations exported verbatim to `sql_silver/live/`; md5 of every file equals the live md5 (EXACT).
- 50 live migrations accounted for in `MIGRATION_LEDGER.md` with live md5, repo match level and rationale. 58 silver functions, 43 tables, 26 views, 3 cron jobs inventoried; every function is referenced by at least one migration.
- Repo vs live differences, all explained: 020 (repo seeds interval 600 and omits the synonyms that live 021c removed; live seeded 120), 021 (repo tail has the later self-test text from 021b/021c). Do not replay either.
- Not verifiable here: 000–003, 005–009 and 024 were not in the repo snapshot I have. `ledger_verify.sql` regenerates md5s to compare in the real repo.
- **Not committed to git:** the repo on your computer is unreachable from this session (device not connected). All files are in the delivered bundle; deployment steps are in the ledger. No migration was renumbered, overwritten or replayed.

## 5. Item 4 — Row-count reconciliation (SQL: `sql_silver/evidence/row_count_reconciliation.sql`)
| Category (scoped at) | Bronze rows | Silver rows | Running total |
|---|---|---|---|
| Frozen Veg Snacks (2026-11-06 16:28 UTC) | 990 | 990 | 990 |
| Soft Drinks (11-07 18:17) | 507,770 | 507,770 | **508,760** |
| Chips & Crisps (11-07 18:57) | 59,144 | 59,144 | 567,904 |
| Indian Sweets (11-07 18:57) | 990 | 990 | 568,894 |
| Chocolates (11-07 18:57) | 690 | 690 | 569,584 |
| Noodles (11-07 18:57) | 552 | 552 | **570,136** |
| Prescription Medicines (not scoped) | 210 | 0 | — |
| **Total** | **570,346** | **570,136** | |
**508,760** = Soft Drinks + Frozen Veg, the only two categories scoped at the time of the earlier count; **570,136** = after the other four categories were scoped. The 210 bronze rows left out belong to a category with 7 stores (below the 10-store threshold `category_min_stores`) — intentional, not a loss. Checks: 0 non-ok bronze snapshots, 0 silver rows without a bronze source, 0 duplicate `source_record_id`, 0 in-scope bronze rows missing.

## 6. Item 5 — Automation verification
| Item | Evidence |
|---|---|
| 120 s interval | `pipeline_min_interval_seconds` = 120 (set by repo 025; 020 seed 600 superseded). Debounce test: last run 119 s ago + new data → `debounced`. Live: successive cron runs 20:01, 20:03, 20:05, 20:08, 20:12, 20:15 (≥ 2 min apart, each picked up new scraper data) |
| Cron jobs | exactly 3, no duplicates: `sidnl-pipeline` `* * * * *` → `run_tick()`; `sidnl-pipeline-daily` `35 18 * * *` (= 00:05 IST) → `enqueue_daily`; `sidnl-gold` `* * * * *` → `run_gold_pending()`. Temporary test job created and removed |
| Daily 00:05 IST | next daily 2026-11-08 18:35 UTC = 2026-11-09 00:05 IST; one daily job per IST date (second and third `enqueue_daily` return NULL); last cron daily run 11-07 18:36 UTC succeeded; catch-up after 00:05 IST exists (job 1) |
| Queued-job recovery | job queued 3 h earlier (simulated outage) was picked up by the next tick and finished `success` |
| Retry | transient error: waits 2, 4, 8, 16 min, 5th attempt `failed`; permanent (23505): `failed` at attempt 1; transient then success: `success`, error cleared |
| Category isolation | injected error in Noodles: the other 5 scopes loaded and advanced watermarks, Noodles watermark held, run `partial`, job `retry_wait` 2 min, Gold `skipped` |
| Gold separate | `run_pipeline` does not call `gold.refresh_all`; only `run_gold_pending` does, on its own cron job. History of Silver run statuses: success 56, partial 6 (all 18:17–18:30 UTC, before this work's deployment), blocked 3 (19:22–19:27, before the data fix); Gold only follows successful Silver runs and a Gold failure cannot change a Silver run status |
Gold logic untouched.

## 7. Item 6 — Final validation (all destructive tests ran inside rolled-back transactions on real rows)
| Area | Result |
|---|---|
| Data quality gates | one shelf row without product, store or brand each → `blocking`, scope blocked; one negative price → `rejected`, not blocking (below `dq_reject_block_pct` 5 %); 25 price > MRP → `warning`, never blocks; whole scope negative → blocks. Baseline: 0 blocking, 0 rejected, 0 warning; accepted: 181 stores without city/coords, 13 products without category, 34 empty `name_clean` |
| Watermarks | all 6 category watermarks and all bronze shelf watermarks equal bronze max (570,346). Deleting 50 newest Noodles rows and moving the watermark back: incremental load inserted exactly 50, updated 0, checksum equal to original; rerun 0/0 |
| Updated rows | 30 changed rows corrected by full reload exactly 30; second reload 0/0 |
| SI id integrity | 2,032 products, 2,032 mapped, 0 with more than one SI id, 0 xref to inactive ids, 0 active SI without member, 2,027 active + 4 merged (same 4 as before; 2,016 + 11 new), 0 duplicate (platform, product id), 0 shelf rows pointing to a wrong product, 0 unlinked, 1 review pending (SI121/SI449), 0 approved, no merge made |
| Idempotency | shelf: rerun 0/0, double full reload 0/0; brands: double full reload 0/0 |
| Concurrency | real second session (pid 180042) held advisory lock 727100: both a forced and a regular run returned `skipped` |
| Failure recovery | see item 5 (retry, permanent, recovery, queued job, isolation) |
Count differences from the previous report, explained: stores without city/coords 182 → 181 and products without category 14 → 13 because bronze `public.stores` / listings gained those values; Silver equals bronze (0 mismatches over 1,085 stores).

## 8. Findings and remaining items
1. (Resolved by 044 for monitoring) **Statement timeouts bypass the job table.** PL/pgSQL `EXCEPTION WHEN OTHERS` cannot catch SQLSTATE 57014 (query canceled), so a timeout aborts the whole cron call: the transaction rolls back, watermarks do not move and the next tick retries, but no `pipeline_job` row or backoff is written. Only the three timeouts from the earlier initial load have happened (before this work); 0 since. 043 adds `silver.v_cron_health` (failures, consecutive failures, last message). A hard fix would need a supervisor outside PL/pgSQL; I did not add one. 044 adds the alert on `consecutive_failures >= 3`. Limitation: the alert is raised from `run_tick`; if cron/`run_tick` never starts at all, nothing can alert from inside the database.
2. **Compute Disk allocation UNVERIFIED** (see sign-off section). `storage_plan_gb`=8 is an assumption, not evidence, and was not changed.
3. The 2026-11-08 daily job is `blocked` (ran at 19:27 UTC before the data fix); forced run 56 covered it. Next daily 11-08 18:35 UTC.
4. Full-mode category reload sets a category watermark to that category's max id (e.g. Noodles 570,086), incremental sets the global max; both are safe (never beyond loaded rows).
5. Late bronze corrections beyond the 5,000-id lookback are healed by the daily forced run only (bronze has no `updated_at`).
6. Repo commit and parity of migrations 000–003/005–009/024 pending the real repo (see item 3).
7. `silver.demo` view and `dim_platform.demo` (is_test) pre-exist and were not touched; test rows kept as evidence: job 24, runs 60 and 62.
8. Correction to an earlier statement of mine: the brand loader steps took about 3 s before and after 041; the 25–35 s I mentioned is the whole run.

## 9. Health now (`silver.v_silver_health`)
healthy · last run success · 0 blocking violations · 0 unlinked · 0 products without SI id · 1 review pending · 0 jobs waiting retry · 0 failed in 24 h · Gold success · bronze behind watermark 0 · DB 578 MB.

Files: `sql_silver/041–043_*.sql` + rollbacks, `sql_silver/live/*.sql`, `sql_silver/MIGRATION_LEDGER.md`, `sql_silver/ledger_verify.sql`, `sql_silver/evidence/row_count_reconciliation.sql`, `docs_silver/SILVER_OPERATIONS.md`.


## 10. Final sign-off round (2026-11-08)
**Already complete before this round:** items 1–6 (041 brand no-op guard, 042 storage monitoring, ledger/exports, row-count reconciliation, automation verification, validation).
**Completed now:** 044 cron failure alert + tests; manifest of all 51 live migrations (`LIVE_MIGRATION_MANIFEST.csv`); read-only parity script (`verify_repo_parity.py`); repo-ready staging notes; PDF metric mapping; re-validation.
**Pending (blocks sign-off):**
1. **Compute Disk allocation — UNVERIFIED.** Billing "Storage Size" quota (100 GB, Pro) is a different thing from the Postgres Compute Disk size. No tool available to me exposes disk size (project API returns none) and I have no dashboard access. Needed from you (Dashboard → Project Settings → Compute and Disk): disk size (GB), disk type, provisioned IOPS/throughput, compute size, and whether disk auto-scaling shows current usage. Then I set `storage_plan_gb` to that value (only with evidence). Current usage is about 1.7 GB.
2. **Git commit — none made, no hash.** The linked computer was unreachable on every attempt (including this round); the repo snapshot I have is read-only and partial.
3. **Historical parity 000–003, 005–009, 024 — unverified** (not in my snapshot). Run `python verify_repo_parity.py LIVE_MIGRATION_MANIFEST.csv <repo>/sql/silver` locally. Current result vs snapshot: 7 EXACT, 9 BODY, 14 COMMENTS-ONLY, 2 KNOWN-DIFF (020, 021: repo copies differ from live; never replay), 19 not in snapshot. All live checksums are preserved (no migration was edited or replayed).
4. Decision for you: 130 historical shelf rows (one store, city now `thane`) carry a stale NULL `city_slug`. Nothing was changed. The next forced daily run (2026-11-08 18:35 UTC) corrects it automatically; tell me if you want it earlier or held.

**Cron alert evidence (all tests inside rolled-back transactions; fake `job_run_details` rows used negative runids and none remain).**
- 043 defect found: with 1 failed + 1 running execution the view reported 2. 044 counts `status='failed'` only → 1. Running/starting/sending/connecting never count.
- A success resets the streak (counting starts after the last `succeeded`).
- Threshold from `sidnl_config.cron_alert_consecutive_failures` (3): 2 failures → no alert; 3 → one `alert` row in `silver.cron_alert_log`; further checks do not duplicate (repeat only after 1 day); a following success → one `recovered` row. `silver.cron_alert_log` has 0 rows now (tests rolled back).
- Real concurrency re-test with a temporary pg_cron lock holder: `run_pipeline(true)` and `run_pipeline(false)` both returned `skipped`; temp job unscheduled. `cron.job` now holds only jobs 1, 2, 6.

**Final validation (read-only / reversible):** health healthy; DQ 0 blocking/rejected/warning; watermarks consistent; SI-ID integrity clean (0 products without SI id, no ids changed, no merges); idempotent re-run writes 0 changed brand rows; retry ladder 2/4/8/16 min, 5 attempts; Gold only via `sidnl-gold`, untouched; last cron run succeeded.

**Final Silver health status: healthy operationally; sign-off blocked on items 1–3 above.**

## 11. PDF metric mapping (from `silver.ref_metric_support`, 55 PDF metric groups)
Counts: direct 6, derived 8, partial 9, proxy 5, not available 27.
Captured data today: shelf positions 570,136 rows (1,072 stores, 16,536 ad rows), product readings 8,137 (2,803 stock-check/OSA-eligible, 3,549 unavailable), store scans 3,333, 2,032 products, 1,085 stores.
**Computable now:** MRP, SP, discount amount/% (direct); assortment, dark-store listing %, OSA, average OSA, OSA D-1/D-2/D-3, top cities/SKUs, price threshold difference (derived); FE inventory (units from scrape); price difference across platform/store/city (partial).
**Proxy / partial (definition caveats, confirm with you):** average SP and weighted discount (simple averages, no sales weights); SOV overall/organic/paid/top-of-search/category impression and competitor share/discount/ASP (from shelf rows: share of listed positions, not impressions or sales); PSL, priority, critical SKU (OSA x price, no sales); assortment coverage % (no target list stored); RCA checks.
**Not available (source tables empty — vendor-portal data never loaded; all counts verified 0):** sales value/qty, market share/size, brand contribution, BE inventory, DRR, DOI, inventory value, days to expiry, slow-moving, weighted listing/OSA, all PO/GRN/invoice/debit-note/payment metrics (fill rate, deficit, delays, lead time, credit days, TDS, payable), estimated lost units, sales impact, KW volume, ad spend. Tables `fact_sales_daily`, `fact_inventory_snapshot`, `fact_po_line`, `fact_grn_line`, `fact_invoice`, `fact_debit_note`, `fact_payment`, `fact_ad_keyword_daily`, `fact_category_sales` and `public.vp_ingest_batch` all have 0 rows. No demo data was added; these need a real vendor-portal feed.
