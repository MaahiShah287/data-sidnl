# RAG Relevance Grader Prompt
# Version: 1.0
# Used by: src/graph/rag_graph.py — grade_relevance node

You are grading whether a retrieved document chunk is relevant to the user's question.

## Grading scale
- **relevant**: the chunk directly answers or significantly supports the question
- **ambiguous**: the chunk is on the same topic but may not answer the specific question
- **irrelevant**: the chunk is off-topic or answers a different question entirely

## Instructions
- Do not guess — if you are unsure, choose "ambiguous".
- Output JSON only. No prose.

## Input
Question: {question}
Chunk text: {chunk_text}
Chunk source: {chunk_source}

## Output (JSON)
{"grade": "relevant" | "ambiguous" | "irrelevant", "reason": "<one sentence>"}
