# Rolling back 004 (gold cleanup)

004 drops derived data only. Everything comes from silver, so a rollback rebuilds it rather than restoring it from a backup.

1. **Restore the functions** saved by 004 (tag `pre_dash_004`), oldest dependency first:
   ```sql
   select definition from ops.function_backup where tag = 'pre_dash_004' and fn like 'gold.%' order by fn;
   select definition from ops.function_backup where tag = 'pre_dash_004' and fn like 'silver.run_gold_pending%';
   ```
   Run each `definition`. `gold_stage.*` functions need their schema and tables first (step 2).
2. **Recreate the tables:**
   - The gold summary tables come from `sql/gold/001_gold_schema.sql` … `012_gold_pdf_metrics.sql`.
   - The `metric_*` tables and the `gold_stage` schema come from `sql/gold/archive/102_lean_metric_tables.sql`.
   - Then run each saved `view gold.*` definition from `ops.function_backup`.
3. **Re-fill:** `select gold.refresh_all(); select gold_stage.refresh_metrics();`

`dash.*`, the `dim_*` tables, `cfg_*` and `v_valid_reading` are untouched by 004 and need no rollback.
