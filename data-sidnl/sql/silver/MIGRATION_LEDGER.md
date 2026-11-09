# SIDNL Silver — Verified Migration Ledger

Verified against `supabase_migrations.schema_migrations` on project `jqxnaqbvwgmfkyzfincy` (51 live migrations).
Method: md5 of the live `statements` text vs md5 of the repo/exported file. No migration was renumbered, overwritten or replayed.

## Match levels
- **EXACT**: file is byte-identical to the live migration text (md5 equal).
- **BODY**: identical after removing the 2-line export header (`-- Applied to Supabase…`).
- **COMMENTS-ONLY**: identical after removing `--` comments and collapsing whitespace.
- **KNOWN-DIFF**: differs in content; explained below. Live is authoritative.

## Live migrations by scope
| Version | Name | Live md5 | Repo status |
|---|---|---|---|
| 20261106085949 | ecomscraper_schema_0001_to_0012 | 028800cc82736c7fee89b4f85963a15f | out of Silver scope (bronze) |
| 20261106104107 | silver_000_schema_and_config | 716f9867a83819794df341525928932d | not in provided repo snapshot — verify in real repo |
| 20261106104117 | silver_001_parse_functions | 031a5134978955fa58f62ace1630b55e | not in provided repo snapshot |
| 20261106104238 | silver_001b_fix_parse_pack_word_boundary | df257b94c5c9c315e99165767aeac011 | **EXACT** `live/20261106104238_…sql` (was live-only) |
| 20261106104306 | silver_001c_selftest_parser | 44281c49be5be02edd41e235e7c7e80e | **EXACT** `live/…` (was live-only) |
| 20261106104407 | silver_002_dimensions | 1b03e4a9561f2e77c8709cefa114afba | not in provided repo snapshot |
| 20261106104423 | silver_003_facts | e2568ffbd0ddc4cb6e8e12ae31902eb2 | not in provided repo snapshot |
| 20261106104650 | silver_004_refresh | aaede9d326ed4db43e251baa67b69a78 | repo `004_refresh.sql` = COMMENTS-ONLY match |
| 20261106104957 | silver_005_views | 85b425c03f75886a8c066cd2886d8fcb | not in provided repo snapshot |
| 20261106105006 | silver_006_compat_views | d2b15e4cd160f15aa541aebbe85dd138 | not in provided repo snapshot |
| 20261106105305 | silver_007_metric_catalog | efca4c0a204e9dc32d2ca06efe0b6b3c | not in provided repo snapshot |
| 20261106105311 | silver_008_security | f3069f15b5a4505deb835b68b7926484 | not in provided repo snapshot |
| 20261106105356 | silver_009_function_search_path | bdc624181166509a031824fe34728f64 | not in provided repo snapshot |
| 20261106161405 / 161445 / 161531 / 162933 | gold_* (4) | see query | **Gold — out of scope, untouched** |
| 20261106162817 | silver_category_market_shelf | 6d9347fa0d67e93600fd96fab0f3965e | **EXACT** `live/…` (was live-only, unnumbered) |
| 20261106171023 | bronze_001_vendor_portal | 85100913f73a4e185bbaa1b682fb631d | out of Silver scope |
| 20261106171048 | silver_010_target_dims_facts | fd10ab1b3b8a3182936a17d940c62157 | **EXACT** `live/…` (was live-only) |
| 20261106171214 / 171234 / 171259 | gold_020a/b/c | see query | **Gold — out of scope, untouched** |
| 20261107092022 | silver_020_canonical_schema | 572fb5949d3a8386855e8921bdd55bfb | **KNOWN-DIFF** (see below) |
| 20261107093122 | silver_021_matcher | cc535fec95b7230aba960ebb03c614a7 | **KNOWN-DIFF** (see below) |
| 20261107093215 | silver_022_sidnl_lookup | 52a5155ed24fff33c0bedc30d61d6f3d | repo `022_sidnl_lookup.sql` = COMMENTS-ONLY match |
| 20261107093338 | silver_023a_pipeline_function | 2304dc6f1af3ce9057772021cb3eb6d6 | **EXACT** `live/…` (was live-only) |
| 20261107093523 | silver_023b_pipeline_schedule | 8ecbb800a47a6f73f43a7886285e3081 | **EXACT** `live/…` (was live-only) |
| 20261107093533 | silver_024_security_canonical | 78855ad1e98c838ce3b4081aba7de10e | not in provided repo snapshot |
| 20261107093853 | silver_021b_selftest_real_data_only | ad7fd3cff4fe4709c8024a5f8bc78cfe | **EXACT** `live/…` (was live-only) |
| 20261107093931 | silver_021c_remove_invented_synonyms | da5c2c502ac80d63bf1b35b50c34f647 | **EXACT** `live/…` (was live-only) |
| 20261107101939 | silver_025_incremental_automation | c73500f56ae9b8faff60e010f957bd93 | repo `025_incremental_automation.sql` = COMMENTS-ONLY match |
| 20261107180938 | silver_026_category_pipeline | 9993450c4c429f2689aee76226de1651 | 026 = BODY |
| 20261107181510 – 20261107185921 | silver_027 … 035 | see query | 027–031, 033–035 = BODY; 032 = COMMENTS-ONLY |
| 20261107192120 | silver_036_quality_gate_watermark | 84a74d2e39acf4c4e539317af373a802 | COMMENTS-ONLY (one inline comment differs) |
| 20261107192623 | silver_037_job_state_retry_isolation | af1241ace1eab114a2b1de86517bd576 | COMMENTS-ONLY |
| 20261107192925 | silver_038_deterministic_corrections | 3e166bae129f300cc9d65c00818ba990 | COMMENTS-ONLY |
| 20261107193239 | silver_039_storage_health_fk | fdf53bf18cbfed3555bab71ae00cd1b8 | BODY |
| 20261107194416 | silver_040_job_recheck_timing | f61f81c3f71f5f934e4ec99ae4dd95a4 | BODY |
| 20261107195949 | silver_041_brand_loader_noop_guard | 8436de9be91bd9f1eb6168ec27cd8654 | BODY |
| 20261107200119 | silver_042_storage_alerts | c5dda22df9eb49e55a1599e36635fd03 | COMMENTS-ONLY |
| 20261107201340 | silver_043_cron_health_view | 9eca632f45e2b34c8f43c5324efc7035 | COMMENTS-ONLY (view superseded by 044, still live-ordered) |
| 20261107202823 | silver_044_cron_failure_alert | df8d9f847d3be85acf269777eb18a198 | COMMENTS-ONLY (comments-stripped c16a3babd60635b68af367d8c0da2209) |
| 20261109065005 | silver_050_views_security_invoker | 0cbfb42fcb58e2716d2b78010ae5789e | EXACT (`live/20261109065005_silver_050_views_security_invoker.sql`; applied 2026-11-09; rollback `050_rollback.sql`) |

Full authoritative list with md5 for every row: run `ledger_verify.sql` (below) — it regenerates this table from the live database.

## Known differences (repo vs live) — decisions needed from you only if you want the repo changed
1. **020_canonical_schema** — repo seeds `pipeline_min_interval_seconds = 600` and omits the synonym rows `chili/chilly/chille`, `vegetable(s)`, `samosas/samose`; live 020 seeds 120 and includes those synonyms. Live state was subsequently corrected by live `021c` (synonyms removed) and by `023b`/`025` (interval 600 → 120). Final DB state equals the repo's intent for synonyms; interval is 120 (repo 025 sets it). **Do not replay 020.**
2. **021_matcher** — identical for the first ~18,000 normalised characters; the tail (self-test functions) differs because live `021b`/`021c` replaced them later. Repo file already carries the later self-test text. **Do not replay 021 over live.**

## Live-only objects (before this round) → now exported
`live/` contains 8 migrations that existed only in the database: 001b, 001c, 010, 021b, 021c, 023a, 023b, category_market_shelf. Each file's md5 equals the live md5 (table above).

## Live object inventory (silver schema)
58 functions · 43 tables · 26 views · 25 sequences · 3 cron jobs. All 58 silver functions are referenced by at least one migration text (0 function names found in no migration) — no function exists only by manual DDL.
Cron jobs (all active): `sidnl-pipeline` `* * * * *` → `silver.run_tick()`; `sidnl-pipeline-daily` `35 18 * * *` (00:05 IST) → `silver.enqueue_daily('cron-daily', false)`; `sidnl-gold` `* * * * *` → `silver.run_gold_pending()`.
Two caveats: (a) function *names* appearing in migration text does not prove the live *definition* equals any one migration (later migrations patch earlier functions); the authoritative current definitions are in the database and in `silver.function_backup` snapshots; (b) migrations 000–003, 005–009, 024 were not in the provided repo snapshot, so repo parity for them must be checked in the real repo with the script below.

## Deployment instructions
**New environment (empty database):** do NOT replay by filename. Use the live history order (versions above). Apply in version order the exact live statements; for 026+ use the numbered files (header comments are harmless). `live/` files fill the gaps (001b, 001c, 010, 021b, 021c, 023a, 023b, category_market_shelf). 020/021 must be applied as the live text (export with the query below), not the repo copies.
**Existing production:** nothing to deploy. Commit `sql_silver/*.sql`, `sql_silver/live/*.sql`, rollbacks and this ledger to the repo; no database change is needed.
**Applying a future migration:** `apply_migration` with name `silver_NNN_slug` → export statements → add to repo with the same number → record md5 here.
**Rollback order (newest first):** 050 → 044 → 043 → 042 → 041 → 040 → 039 → 038 → 037 → 036 (each `NNN_rollback.sql`; 041 restores from `silver.function_backup` tag `pre_041`, 042 drops only additive objects).

## ledger_verify.sql (run anytime; read-only)
```sql
select version, name, length(array_to_string(statements, E'\n')) len,
       md5(array_to_string(statements, E'\n')) exact_md5,
       md5(btrim(regexp_replace(regexp_replace(array_to_string(statements, E'\n'), '[ \t]*--[^\n]*', '', 'g'), '\s+', ' ', 'g'))) comments_stripped_md5
from supabase_migrations.schema_migrations order by version;
```
Compare `exact_md5` with `md5sum` of a repo file written without a trailing newline, or `comments_stripped_md5` with the same normalisation applied to the file.


## Sign-off additions
- `LIVE_MIGRATION_MANIFEST.csv`: version, name, length, exact_md5, comments_stripped_md5 for all 51 live migrations (generated from the live table; nothing edited or replayed).
- `verify_repo_parity.py` (read-only): `python verify_repo_parity.py LIVE_MIGRATION_MANIFEST.csv <repo>/sql/silver`. Levels EXACT / BODY / COMMENTS-ONLY / KNOWN-DIFF / MISSING.
- Result vs the partial snapshot I could read: 7 EXACT, 9 BODY, 14 COMMENTS-ONLY, 2 DIFF (020, 021 — never replay), 19 MISSING (000–003, 005–009, 024 and non-silver migrations). Parity for those historical versions is UNVERIFIED until run against the real repo. No git commit was made (no hash).
