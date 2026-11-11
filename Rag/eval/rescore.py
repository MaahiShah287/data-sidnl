"""
eval/rescore.py — re-score a saved reports/eval_results.jsonl without calling
the API again.

The stored records keep the full response, so scoring changes (for example the
`_scoring_numbers` fix that stops row counts and dates from being flagged as
hallucinations) can be applied without re-running 150 LLM calls.

Usage:
    python eval/rescore.py [reports/eval_results.jsonl]
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_eval  # noqa: E402

PROJECT_ROOT = Path(__file__).resolve().parent.parent
QUESTIONS_FILE = PROJECT_ROOT / "eval" / "questions.jsonl"
DEFAULT_RESULTS = PROJECT_ROOT / "reports" / "eval_results.jsonl"
OUT_FILE = PROJECT_ROOT / "reports" / "eval_results.rescored.jsonl"


def main() -> int:
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_RESULTS
    if not src.exists():
        print(f"ERROR: {src} not found")
        return 1

    questions = {
        q["id"]: q
        for q in (
            json.loads(line)
            for line in QUESTIONS_FILE.read_text(encoding="utf-8").splitlines()
            if line.strip()
        )
    }
    records = [
        json.loads(line)
        for line in src.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]

    for r in records:
        q = questions.get(r.get("id"), {})
        r["scores"] = run_eval.score_response(q, r.get("response"), r.get("exception"))

    OUT_FILE.write_text(
        "\n".join(json.dumps(r, default=str, ensure_ascii=False) for r in records) + "\n",
        encoding="utf-8",
    )
    print(f"Re-scored {len(records)} records -> {OUT_FILE}")

    p1 = [r for r in records if r.get("pass") == 1]
    print(f"\n--- Rescored summary (pass 1, {len(p1)} questions) ---")
    for key in [
        "route_correct", "abstain_correct", "no_data_correct", "no_demo_leak",
        "sql_safe", "retry_ok", "numeric_grounded", "numeric_correct",
        "scope_stated", "source_cited",
    ]:
        vals = [r["scores"].get(key) for r in p1 if r["scores"].get(key) is not None]
        if vals:
            passed = sum(1 for v in vals if v)
            print(f"  {key}: {passed / len(vals) * 100:.0f}% ({passed}/{len(vals)})")

    hall = [r["id"] for r in p1 if r["scores"].get("hallucination")]
    print(f"  hallucination flagged: {len(hall)}" + (f" -> {hall}" if hall else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
