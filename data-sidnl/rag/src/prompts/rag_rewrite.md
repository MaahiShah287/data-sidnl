# Query Rewrite Prompt
# Version: 1.0
# Used by: src/graph/rag_graph.py — rewrite_query node

The previous retrieval did not find enough relevant chunks for the question below.
Rewrite the question to improve retrieval quality.

## Rules
- Keep the core intent unchanged.
- Make the rewrite more specific, using domain vocabulary
  (e.g. "in-stock rate", "availability", "observation", "shelf position").
- Do not add information that wasn't in the original question.
- Output JSON only.

## Original question
{question}

## Previous rewritten query (if any)
{previous_rewrite}

## Output (JSON)
{"rewritten_query": "<improved query>", "reason": "<one sentence>"}
