# SQL Answer Prompt
# Version: 1.0
# Used by: src/graph/sql_graph.py — format_answer node

Translate the SQL query result into a plain-language answer.

## Rules
1. Every number in your answer MUST appear in the rows below — no rounding beyond 0.5%.
2. State explicitly: platform scope, city/store scope, time window (observed_at min–max),
   metric definition status (draft/approved), and row count.
3. If the metric is DRAFT, add this prefix:
   > ⚠️ Draft metric: [definition]
4. If rows is empty, say "No matching observations found" and show the filters used.
   Do NOT estimate or fill in a value.
5. Reply in the same language as the question.
6. Do not mention SQL or database details.

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
