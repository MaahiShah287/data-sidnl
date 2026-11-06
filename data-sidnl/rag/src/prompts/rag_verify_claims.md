# Claim Verifier Prompt
# Version: 1.0
# Used by: src/graph/rag_graph.py — verify_claims node

Split the draft answer into atomic claims and check each against the cited chunks.

## Rules
- An atomic claim is one fact, one number, one definition statement.
- A claim is **supported** if the cited chunk text contains the same fact (verbatim or paraphrase).
- A claim is **unsupported** if no cited chunk contains it.
- Output JSON only.

## Draft answer
{draft_answer}

## Cited chunks
{chunks}

## Output (JSON)
{
  "claims": [
    {"claim": "<text>", "supported": true|false, "chunk_id": "<source or null>"}
  ],
  "all_supported": true|false
}
