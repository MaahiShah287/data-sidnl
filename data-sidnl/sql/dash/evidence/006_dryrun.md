# dash_006 pre-apply dry run (2026-11-10 ~09:47 UTC)

The migration, five fault-injection checks and the rollback ran in **one implicit transaction** that ended in
`raise exception`, so nothing was committed. (A probe first showed that the SQL tool runs a multi-statement query
as one transaction: same `txid_current()` across statements.) Faults were injected by replacing `dash.refresh` inside
that transaction; no rows were inserted into real tables. The run used real gold run 781.

| Check | Result |
|---|---|
| Baseline | `run_gold_pending` md5 `9a20ecb5…f55e`; `dash.refresh` md5 `1ed2f330…20a5`; pricing 1,252 / availability 50,604 / visibility 39,474 |
| T1 success (real `dash.refresh`) | `{"status":"success","run_id":781,"dash":"success"}`; 10 `refresh_table_state` rows with real counts; view `is_stale=false` |
| T2 transient (`40001`) | gold `failed`, attempt 1, next retry +2.00 min, `dash.refresh_state.last_error` set; **dash counts unchanged** (1,252 / 50,604 / 39,474); immediate re-call -> `idle` (not due) |
| T3 transient, 2nd attempt | attempt 2, next retry +4 min |
| T4 permanent (`22012`) | attempt 3, `error_class=permanent`, `next_attempt_at=null`; view `refresh_failing=true, needs_attention=true` |
| T5 statement timeout (3 s vs `pg_sleep(10)`) | caught: `sqlstate 57014`, transient, attempt 1, retry +2 min. **The UPDATE after a caught timeout works.** |
| Rollback file applied in the same transaction | `run_gold_pending` md5 back to `9a20ecb5…f55e`; table, view, config rows and backup row all gone |
| After the transaction | md5s, row counts, `cron.job` active flags and run 781 identical to baseline |

Post-apply (09:49 UTC): all 3 cron jobs active and succeeded; Silver counts unchanged (fact_product_reading 56,249,
fact_shelf_position 1,832,098, product_xref 7,149, canonical_product 7,141); `run_gold_pending()` -> `idle` (no new
Silver run since 06:20). `refresh_table_state` fills on the next real successful gold refresh.
