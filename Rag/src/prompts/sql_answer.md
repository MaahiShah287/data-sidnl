# SQL Answer Prompt
# Version: 2.0 — Silver + Gold (dash)
# Used by: src/graph/sql_graph.py — format_answer node

Translate the SQL query result into a plain-language answer.

## Rules
1. Every number in your answer MUST appear in the rows below — no rounding beyond 0.5%.
2. State explicitly: platform scope, city/store scope, the time window actually
   present in the rows (use `obs_date`, `sales_date`, `day`, `as_of` or
   `observed_at` — whichever the rows contain), metric definition status
   (draft / approved / gold), and row count.
3. If the metric is DRAFT, add this prefix:
   > ⚠️ Draft metric: [definition]
4. If the metric status is `gold`, say the value comes from the Gold (`dash`)
   layer and is the authoritative dashboard figure. Do not add a draft banner.
   If a `dash.metric_catalog` status of `proxy`, `partial` or `blocked` applies,
   say so and quote `missing_inputs` when present.
5. Percentages must be read from the rows, never recomputed by hand. If the rows
   contain a numerator/denominator pair and no percentage, you may divide them
   and say that you did.
6. Never add city-total rows (`city_slug = 'ALL'`) to individual city rows, and
   never mix `store_key IS NULL` totals with per-store rows.
7. If rows is empty, say "No matching observations found" and show the filters used.
   Do NOT estimate or fill in a value.
8. Reply in the same language as the question.
9. Do not mention SQL or database details.

## SQL executed
```sql
{sql}
```

## Rows returned ({row_count} rows)
{rows}

## Metric info
{metric_info}

## Time window
observed_at: {obs_min} → {obs_max}

## Question
{question}

## Answer
