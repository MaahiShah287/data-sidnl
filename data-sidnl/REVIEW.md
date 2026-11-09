# Silver review

Date: 2026-11-09

Scope: repository files only. No database connection or live catalog was available. No SQL was applied.

## Findings

### Python pipeline

- The current `sidnl` CLI in `sidnl/cli.py` exposes the in-database Silver operations (`silver-run`, `silver-refresh`, `silver-report`, and `silver-test`); it no longer exposes the old Python ingest/stream/normalize/match orchestration.
- `sidnl/ingest.py`, `loader.py`, `match.py`, `normalize.py`, `rules.py`, and `stream.py` are not called from that CLI path. They remain exercised by `tests/test_logic.py`, so deleting them or their configuration/runtime dependencies would break the required logic tests. Keep them as legacy/test code unless the tests are deliberately migrated in a separate change.
- The SQL-first cleanup had removed `common.load_yaml`/`common.ROOT` and the Python dependencies still required by those tests. Those helpers and the existing dependencies are restored; no SQL-pipeline behavior is changed.

### SQL functions and performance

- `silver.refresh_all()` is defined by the early refresh SQL and has no later in-repository caller; the pipeline path instead calls its individual refresh steps. It is a removal candidate, not a proven-safe deletion: external callers and the live function catalog were not available to check.
- `silver.map_new_products()` is called by the pipeline and is not dead code.
- The category refresh definitions in 026, 027, and 029 are successive migration replacements, not evidence that three active refresh implementations execute together. A baseline should contain only the final live definitions.
- The 046 definition of `silver.v_shelf_by_sidnl` reads `fact_shelf_position` directly and joins `v_shelf_position`, which itself reads that fact. Draft 051 removes the explicit second fact reference by appending `product_key` to `v_shelf_position`. This is a plausible scan reduction, but an `EXPLAIN (ANALYZE, BUFFERS)` comparison is still needed on the live database; view inlining may affect the actual plan.
- Keep `silver.ix_canon_name_trgm`: the repository's SIDNL name-search path uses trigram similarity operators, and no evidence here proves the index is unused.
- No SQL rewrite was made for unchanged-row guards or sort removal. Without the live definitions and plans, changing upsert predicates or ordering risks changing row-update semantics.

### Migration parity and baseline risks

- The checked-in parity run finds 050 as `EXACT`, but also reports missing and differing historical entries, including 036–040 and non-silver migration entries. The current manifest has no records for silver 051–055 or gold 060–064, so the verifier cannot check those requested live migrations.
- Drafts 051–053 lack live migration versions and hashes. The repository has no SQL bodies or rollback definitions for 054–055 or gold 060–064. The task describes their outcomes, but not the exact applied statements or Supabase migration versions. Reconstructing those values or generating a purportedly live baseline from them would not be verifiable.
- The repository also contains an untracked, table-based `gold_102` migration set. The user confirmed the authoritative live Gold state is migrations 060–063 with metric-named views; `gold_102` is not that live state and must not be used as its baseline or applied as a substitute.
- Per the user's live test report, `gold.sync_dims()` dropped from 3.1 s to 0.03 s with identical row counts; visibility refresh uses `gold.refresh_state` to update changed shelf dates; refresh-all calls dimension sync once and uses `DELETE` instead of `TRUNCATE`. The report says its rollback test matched prior Gold contents except clock-derived age/freshness. These are reported results, not independently verified here.
- The current 045 file includes `DROP` statements against `public.vp_*`. It is pre-existing and was not edited or applied in this work. Do not replay it or include any `public` change in a new baseline.
- Therefore, do not treat the current numbered SQL set as a reproducible clean baseline, and do not claim repository/live parity until the missing applied SQL and version metadata are available. The baseline must also preserve the existing history and automatic cron behavior, including skipping Gold refresh after a partial Silver run.

## Deployment

No migration was applied by this review. The requested Silver 051–055 and Gold 060–063 are described as already applied in Supabase; the original task also identifies Gold 064 as applied. No further database migration is indicated by the supplied status. The missing work is to export exact applied SQL and metadata into the repo; do not apply the current drafts or archived gold_102 as substitutes.
