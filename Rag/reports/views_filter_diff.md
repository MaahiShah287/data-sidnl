# Diff for sql/01_views.sql — TODO(diagnostics) filter fill
# Generated from: reports/data_profile.md (2026-11-09)
# Decision rationale at bottom.

--- sql/01_views.sql (before)
+++ sql/01_views.sql (after — do NOT apply until confirmed)

## blinkit block (lines 38-41), and identically for zepto/instamart/jiomart:

-    -- TODO(diagnostics): AND scrape_status IN ('<confirmed_success_values>')
-    -- TODO(diagnostics): AND scrape_run_status IN ('<confirmed_success_values>')
+    -- scrape_status: only valid value = 'ok'. BUT 86.1% of blinkit rows have NULL
+    -- scrape_status (all shelf_position rows). Do NOT filter yet — would drop 48,191
+    -- rows. Keep TODO open until scraper team confirms whether NULL = valid or bug.
+    -- TODO(confirmed-pending): AND scrape_status IN ('ok')
+
+    -- scrape_run_status: 100% NULL across all platforms. No filter applicable.
+    -- Remove this TODO — no usable values exist to filter on.

---

## Decision rationale

| Column           | blinkit NULL rows | blinkit 'ok' rows | Zepto NULL | Zepto 'ok' |
|------------------|-------------------|-------------------|------------|------------|
| scrape_status    | 48,191 (86.1%)    | 7,714 (13.8%)     | 0          | 344 (100%) |
| scrape_run_status| 55,905 (100%)     | 0                 | 344 (100%) | 0          |

### scrape_status
- The ONLY non-NULL value across both platforms is `'ok'`.
- However, 86% of blinkit rows (all shelf_position records) have NULL scrape_status.
- Adding `AND scrape_status = 'ok'` would silently drop ALL shelf_position data
  from blinkit (48,191 rows) since those rows have NULL scrape_status.
- **Action**: Keep filter commented out. Add an OPEN QUESTION for the scraper team:
  "Is NULL scrape_status on shelf_position rows intentional or a scraper bug?"

### scrape_run_status  
- 100% NULL for every platform. No filter is possible or useful.
- **Action**: Remove the TODO stub entirely in the next view revision.

### data_quality_status
- 100% = 'valid' for all platforms — the existing filter `= 'valid'` is correct
  and sufficient as the primary quality gate.

## Open question logged
Add to OPEN_QUESTIONS.md:
> Q: Is NULL scrape_status on blinkit shelf_position rows (48,191 records)
> intentional (scraper doesn't set it for shelf jobs) or a bug?
> Until confirmed, we cannot add a scrape_status filter without data loss.
