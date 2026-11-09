# Removes files the new silver design no longer uses. Run once from this folder (the one that contains .git):
#   powershell -ExecutionPolicy Bypass -File .\cleanup_repo.ps1
# Review with `git status` afterwards; nothing is committed or pushed. Delete this script when done.
$ErrorActionPreference = "Continue"
$files = @(
  # old v1 file-ingest / matching pipeline (replaced by the in-database pipeline)
  "data-sidnl/sidnl/ingest.py", "data-sidnl/sidnl/loader.py", "data-sidnl/sidnl/match.py",
  "data-sidnl/sidnl/normalize.py", "data-sidnl/sidnl/rules.py", "data-sidnl/sidnl/stream.py",
  "data-sidnl/sql/001_schema.sql", "data-sidnl/sql/002_pipeline.sql", "data-sidnl/sql/003_dynamic_matching.sql",
  "data-sidnl/config/matching.yaml", "data-sidnl/config/platforms.yaml",
  "data-sidnl/crontab.txt", "data-sidnl/deploy/sidnl-live.service",
  "data-sidnl/landing/.gitkeep", "data-sidnl/logs/.gitkeep",
  # tests (two smoke tests remain in tests/test_silver_sql.py)
  "data-sidnl/tests/test_logic.py", "data-sidnl/sql/silver/tests/test_parse_functions.sql",
  # rollback / evidence / ledger bookkeeping
  "data-sidnl/sql/silver/041_rollback.sql", "data-sidnl/sql/silver/042_rollback.sql",
  "data-sidnl/sql/silver/043_rollback.sql", "data-sidnl/sql/silver/044_rollback.sql",
  "data-sidnl/sql/silver/evidence/row_count_reconciliation.sql", "data-sidnl/sql/silver/ledger_verify.sql",
  "data-sidnl/sql/silver/verify_repo_parity.py", "data-sidnl/sql/silver/LIVE_MIGRATION_MANIFEST.csv",
  "data-sidnl/sql/silver/MIGRATION_LEDGER.md",
  # reports and stale ERD of the old schema
  "data-sidnl/docs/silver/SILVER_AUDIT_AND_PLAN.md", "data-sidnl/docs/silver/SILVER_COMPLETION_REPORT.md",
  "data-sidnl/docs/silver/erd.mmd", "data-sidnl/docs/silver/erd.png", "data-sidnl/docs/silver/erd.svg"
)
foreach ($f in $files) {
  git rm -q -f --ignore-unmatch -- $f 2>$null
  if (Test-Path $f) { Remove-Item -Force $f }
}
foreach ($d in @("data-sidnl/landing", "data-sidnl/logs", "data-sidnl/config", "data-sidnl/deploy", "data-sidnl/sql/silver/tests", "data-sidnl/sql/silver/evidence")) {
  if ((Test-Path $d) -and -not (Get-ChildItem $d -Force)) { Remove-Item $d }
}
Write-Host "Done. Run: git status"
