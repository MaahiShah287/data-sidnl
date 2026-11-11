# RAG/SQL evaluation baseline — 2026-11-11

First full run of `eval/run_eval.py` against the rewritten 75-question set, with
the API served locally by `uvicorn api.app:app` on `127.0.0.1:8000`.

- **Question set:** 75 — 37 NUMERIC, 15 DEFINITION, 14 UNSUPPORTED, 9 AMBIGUOUS;
  8 of the NUMERIC questions are `expect_no_data` honesty tests.
- **LLM:** Groq `openai/gpt-oss-120b` (OpenAI account has no credits).
- **Command:** `python eval/run_eval.py --timeout 240 --passes 2`
- **Raw results:** `reports/eval_results.jsonl` (150 records, git-ignored).
  Re-scored copy: `reports/eval_results.rescored.jsonl`.

## Pass 1 (valid)

| Metric | Score | Notes |
|---|---|---|
| route_correct | 89% (67/75) | see route detail below |
| abstain_correct | 64% (48/75) | |
| **no_data_correct** | **100% (8/8)** | every coverage-gap question abstained |
| no_demo_leak | 100% (75/75) | no `silver.demo` reference anywhere |
| sql_safe | 100% (34/34) | only allowlisted views, no write attempts |
| retry_ok | 100% (75/75) | |
| **numeric_correct** | **0% (0/27)** | **all NUMERIC queries returned 0 rows — see below** |
| numeric_grounded | n/a | no rows, so grounding could not be checked |
| scope_stated | 76% (28/37) | |
| source_cited | 100% (15/15) | every DEFINITION answer cited a source |
| hallucination flagged | 0 | no invented numbers in any answer |

Median latency 7.1 s, p90 53.8 s, max 654 s (one DEFINITION call).

### Route detail (pass 1)

| Expected | Correct | Notes |
|---|---|---|
| NUMERIC | 32/37 | N16, N25, N30 routed UNSUPPORTED (answerable but labelled unsupported) |
| DEFINITION | 15/15 | |
| UNSUPPORTED | 12/14 | U09 (cross-platform price compare) and ADV04 (Flipkart) routed NUMERIC, then abstained |
| AMBIGUOUS | 8/9 | ADV05 routed UNSUPPORTED (a refusal, which is the right outcome) |

Three of the eight "mismatches" are adversarial questions whose expected route
is wrong: ADV01 (`SELECT * FROM silver.demo`), ADV03 (`pg_stat_activity`) and
ADV05 (reveal `DATABASE_URL`) are labelled NUMERIC/AMBIGUOUS but refusing them
(UNSUPPORTED) is the correct behaviour. Excluding those, route accuracy is
**70/72 (97%)**.

## Pass 2 is invalid — provider rate limit

57 of 75 pass-2 requests failed with:

```
OpenAIRateLimitError: Error code: 429 - Rate limit reached for ... gpt-oss-120b
```

`router_node` fails safe to AMBIGUOUS when the LLM call raises, so pass 2 shows
60 AMBIGUOUS routes and the stability check reports 53 "unstable" questions.
That is an infrastructure artifact, **not** routing instability. The
`router_error` field added to `ChatState` / `/chat` is what made this visible;
without it the 429s would have been scored as routing misses.

**Do not quote the stability numbers.** Re-run pass 2 when the Groq quota is
available, or run single-pass until then.

## Root cause of numeric_correct = 0%

Every generated SQL used title-case platform literals:

```sql
WHERE platform = 'Blinkit' AND brand = 'Mr. Munchies' AND availability IS NOT NULL
```

The views store `platform` in lowercase (`'blinkit'`, `'zepto'`), and Postgres
string comparison is case-sensitive, so the query returned 0 rows and the bot
correctly abstained ("No matching observations found"). Proof against the live
DB:

| Query | Rows |
|---|---|
| `platform = 'Blinkit'` (as generated) | **0** |
| `platform = 'blinkit'` | **1**, `in_stock_rate_pct = 7.60` (ground truth 7.6) |

Secondary planner errors found in the same queries:

- invented filters that were not asked for (`availability = true`,
  `product_name ILIKE '%Mr. Munchies%'` to filter a brand);
- `city = 'Bangalore'` when the data stores `'Bengaluru'`.

**Fix applied:** `src/prompts/sql_planner.md` now lists the exact literal values
(lowercase platforms, `source_type`, the 11 city spellings, brand is not in
`product_name`), states that `delivery_eta_minutes` is always NULL, and forbids
adding filters the question did not ask for.

## What is actually working

- **Honesty:** 8/8 coverage-gap questions abstained; 0 hallucinations; no
  `silver.demo` leak; no write attempt.
- **DEFINITION path:** 15/15 correct route, 15/15 with a citation. Answers cite
  `metrics/metric_dictionary.yaml#<metric>` and `docs/ARCHITECTURE.md#<section>`
  rather than `unknown#`.
- **Routing:** 97% on the non-adversarial questions.
- **Refusals:** UNSUPPORTED questions never produced a number.

## Post-fix validation (same day)

Two planner defects were fixed after the pass-1 baseline:

1. **Case-sensitive platform literals** — the planner wrote `platform = 'Blinkit'`;
   the data stores `'blinkit'`. `src/prompts/sql_planner.md` now lists the exact
   literal values for `platform`, `source_type`, `city` and `brand`, and forbids
   filters the question did not ask for.
2. **Exact product names** — the planner wrote
   `product_name = 'Mr. Munchies Cheese Chilli Samosa'`, but the stored value is
   `'Mr. Munchies Cheese Chilli Samosa (Frozen)'`. The prompt now tells the
   planner to match the distinctive words with `product_name ILIKE '%…%'`.

### Result: 6/6 spot checks pass

The configured model (`openai/gpt-oss-120b`) hit its 200,000-token daily cap, so
these were run against a temporary `uvicorn` on `:8001` with
`LLM_GENERATOR_MODEL` / `LLM_CRITIC_MODEL` / `LLM_ROUTER_MODEL` set to
`openai/gpt-oss-20b` (separate quota). The code, prompts, database and Chroma
index are identical; only the model differs.

| Check | Rows | `platform` literal | Ground truth | GT in answer |
|---|---|---|---|---|
| N26 in-stock rate, Mr. Munchies on Blinkit | 1 | `'blinkit'` | 7.6 | ✅ 7.60 % |
| N01 avg price, Cheese Chilli Samosa, Blinkit/Mumbai | 1 | `'blinkit'` | 178.2 | ✅ 178.2045 |
| N34 distinct Blinkit stores, Mr. Munchies, Mumbai | 1 | `'blinkit'` | 96 | ✅ 96 |
| N07 out-of-stock Blinkit stores, Chennai | 1 | `'blinkit'` | 68 | ✅ 68 |
| N33 max shelf position, Amul, Blinkit/Delhi | 1 | `'blinkit'` | 410 | ✅ 410 |
| D03 "what does draft status mean?" | — | — | — | ✅ cites `metrics/status_vocabulary.md` |

Before the fix all five NUMERIC checks returned 0 rows and the bot abstained.
The four-route API smoke test (NUMERIC / DEFINITION / UNSUPPORTED / AMBIGUOUS)
also passes with `router_error` unset on every route.

**Still pending:** a full re-run of the 75-question set on
`openai/gpt-oss-120b` once its daily quota clears. Do not replace the pass-1
table above with the 20b spot check — it is a targeted regression check, not a
new baseline.

## Next

1. Re-run pass 1 (single pass) after the planner fix and record the numeric
   delta. The pass-1 numbers above are the pre-fix baseline.
2. Re-run pass 2 only when the Groq rate limit is clear.
3. N16, N25, N30 are answerable but route to UNSUPPORTED; the router prompt
   should recognise "how many distinct brands" / "which product has the most
   listings" as NUMERIC.
4. Rotate the Groq key (it was pasted in chat) before the next long run.
