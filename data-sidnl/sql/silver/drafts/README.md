# Draft migrations from the view audit — NOT APPLIED

Source: `docs/silver/SILVER_VIEW_AUDIT.md` §6–§7 (2026-11-09). Each draft has a `NNN_rollback.sql`.

| Draft | Change | Risk | Dry run on live (rolled back) |
|---|---|---|---|
| ~~`050_views_security_invoker`~~ | **APPLIED 2026-11-09** as version `20261109065005`. The file now lives in `live/` and the rollback in `../050_rollback.sql`. | — | After apply: 0 owner-rights views; all row counts unchanged; cron green |
| `051_shelf_view_product_key` | Append `product_key` to `v_shelf_position`; rebuild `v_shelf_by_sidnl` without reading the 1M-row fact table a second time | Additive column only | `v_shelf_by_sidnl` 1,006,016 rows (same as before), 40 columns (39 + `product_key`) |
| `052_fk_guard_view_inputs` | FKs so that deleting a `freshness_policy` / `category_scope` row fails instead of silently hiding history in `v_reading` / `v_shelf_position` | A scope row can no longer be deleted while it has shelf rows; use `is_enabled=false` instead. VALIDATE scans ~1M rows. | Not run as DDL (lock on the hot fact table). Orphan check: 0 and 0, so VALIDATE will pass. |
| `053_retire_unused_views` | Drop `v_category_shelf`, `v_dim_product_sidnl` | External callers can't be seen from the catalog. Check the API logs first. | 17 views after the drop; the rollback restores identical definitions |

After every rollback, all 19 view definitions and reloptions were byte-identical (md5) to the state before the dry run.

**Apply order:** 050 → 051 → 052 → 053, each via `apply_migration` named `silver_NNN_slug`. Then move the file into `live/` with its version, and record its md5 in `MIGRATION_LEDGER.md` and `LIVE_MIGRATION_MANIFEST.csv`. Roll back in reverse order.

**Not drafted (out of SQL scope or contract-breaking):** dropping `demo`/`instamart`/`jiomart` (the RAG and gold scripts reference them by name); `v_wide.source_type` being lossy (renaming the values breaks the legacy contract); the three RAG views that are missing in the database (`Rag/sql/01_views.sql` was never applied, so fix that in the RAG repo); which category to treat as authoritative in `v_sidnl_product` vs `v_canonical_product_map` (a business decision).
