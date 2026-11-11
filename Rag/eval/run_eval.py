"""
eval/run_eval.py — Sends every question in questions.jsonl to POST /chat,
scores each response, and writes reports/eval_results.jsonl.
Then runs a second pass to detect instability.

Usage:
    python eval/run_eval.py [--api-url http://localhost:8000] [--timeout 60]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

try:
    import httpx
except ImportError:
    print("ERROR: httpx not installed. Run: pip install httpx")
    sys.exit(1)

PROJECT_ROOT = Path(__file__).resolve().parent.parent
QUESTIONS_FILE = PROJECT_ROOT / "eval" / "questions.jsonl"
RESULTS_FILE   = PROJECT_ROOT / "reports" / "eval_results.jsonl"
REPORTS_DIR    = PROJECT_ROOT / "reports"
REPORTS_DIR.mkdir(exist_ok=True)


# ---------------------------------------------------------------------------
# Scoring functions
# ---------------------------------------------------------------------------

def _numbers_in_text(text: str) -> set[float]:
    matches = re.findall(r"\b\d+(?:\.\d+)?\b", text or "")
    return {float(m) for m in matches}


def _in_rows(val: float, rows: list[dict], tol: float = 0.005) -> bool:
    for row in rows:
        for rv in row.values():
            try:
                rv_f = float(rv)
                if abs(val - rv_f) <= abs(val * tol) + 0.001:
                    return True
            except (TypeError, ValueError):
                pass
    return False


def score_response(question_rec: dict, resp: dict | None, exception: str | None) -> dict:
    if exception or resp is None:
        return {
            "route_correct": False, "abstain_correct": False,
            "no_data_correct": None,
            "numeric_grounded": None, "numeric_correct": None,
            "scope_stated": None, "draft_noted": None,
            "no_demo_leak": True, "sql_safe": None,
            "retry_ok": None, "lang_match": None,
            "source_cited": None, "hallucination": False,
            "error": exception or "no response",
        }

    expected_route   = question_rec.get("expected_route", "")
    expect_abstain   = question_rec.get("expect_abstain", False)
    # Coverage-gap questions: the data cannot answer them, so the correct
    # behaviour is to say "no data" rather than to answer something else.
    expect_no_data   = question_rec.get("expect_no_data", False)
    actual_route     = resp.get("route", "")
    actual_answer    = resp.get("answer", "") or ""
    actual_abstain   = bool(resp.get("abstain_reason"))
    rows             = resp.get("rows", []) or []
    sources          = resp.get("sources", []) or []
    sql              = resp.get("sql", "") or ""
    retry_count      = resp.get("retry_count", 0)
    metric_status    = resp.get("metric_status", "") or ""

    scores = {}
    scores["route_correct"]   = actual_route == expected_route
    scores["abstain_correct"]  = actual_abstain == (expect_abstain or expect_no_data)

    # Coverage-gap questions pass only if the bot refuses to answer.
    # Returning a number here means it silently changed the filters.
    scores["no_data_correct"] = actual_abstain if expect_no_data else None

    # Numeric grounding: every number in answer must be in rows
    if expected_route == "NUMERIC" and not expect_abstain and not expect_no_data and rows:
        nums = _numbers_in_text(actual_answer)
        if nums:
            ungrounded = [n for n in nums if not _in_rows(n, rows)]
            scores["numeric_grounded"] = len(ungrounded) == 0
            scores["hallucination"] = len(ungrounded) > 0
        else:
            scores["numeric_grounded"] = None  # no numbers to check
            scores["hallucination"] = False
    else:
        scores["numeric_grounded"] = None
        scores["hallucination"] = False

    # Numeric correctness against ground truth
    gt_val = question_rec.get("ground_truth_value")
    if gt_val is not None and expected_route == "NUMERIC" and not expect_no_data:
        answer_nums = _numbers_in_text(actual_answer)
        try:
            gt_f = float(gt_val)
            scores["numeric_correct"] = any(
                abs(n - gt_f) <= abs(gt_f * 0.005) + 0.001 for n in answer_nums
            )
        except (TypeError, ValueError):
            scores["numeric_correct"] = None
    else:
        scores["numeric_correct"] = None  # no ground truth loaded yet

    # Scope stated: platform, city/store, time window, row count
    scope_keywords = ["platform", "city", "store", "observed", "row", "result"]
    scores["scope_stated"] = (
        sum(kw in actual_answer.lower() for kw in scope_keywords) >= 2
        if expected_route == "NUMERIC" else None
    )

    # Draft metric noted
    scores["draft_noted"] = (
        "draft" in actual_answer.lower()
        if metric_status == "draft" else None
    )

    # No silver.demo leak
    scores["no_demo_leak"] = (
        "silver.demo" not in actual_answer.lower()
        and "silver.demo" not in sql.lower()
    )

    # SQL safe: only allowlisted views
    allowed = {"silver.v_all_platforms", "silver.v_latest_observation", "silver.v_latest_shelf_position"}
    if sql:
        sql_lower = sql.lower()
        unsafe_refs = [
            t for t in ["silver.blinkit", "silver.zepto", "silver.instamart",
                        "silver.jiomart", "silver.demo"]
            if t in sql_lower
        ]
        scores["sql_safe"] = len(unsafe_refs) == 0
    else:
        scores["sql_safe"] = None

    # Retry within cap
    scores["retry_ok"] = retry_count <= 2

    # Language match (heuristic)
    q_lang = question_rec.get("notes", "")
    if "hinglish" in q_lang.lower() or "hindi" in q_lang.lower():
        # Very rough heuristic — accept any response for now
        scores["lang_match"] = True
    else:
        scores["lang_match"] = True  # English baseline — always pass

    # Source cited for DEFINITION
    scores["source_cited"] = (
        len(sources) > 0
        if expected_route == "DEFINITION" else None
    )

    # Hallucination for UNSUPPORTED: must abstain, not give a number
    if expected_route == "UNSUPPORTED":
        answer_nums = _numbers_in_text(actual_answer)
        if answer_nums and not actual_abstain:
            scores["hallucination"] = True

    return scores


# ---------------------------------------------------------------------------
# Main runner
# ---------------------------------------------------------------------------

def run_pass(questions: list[dict], api_url: str, timeout: int, pass_num: int) -> list[dict]:
    results = []
    for i, q in enumerate(questions, 1):
        qid = q.get("id", f"Q{i:03d}")
        question_text = q.get("question", "")
        print(f"[pass {pass_num}] {qid}/{len(questions)} — {question_text[:60]}…")

        wall_start = time.monotonic()
        resp_json = None
        exception = None
        http_status = None

        try:
            with httpx.Client(timeout=timeout) as client:
                r = client.post(f"{api_url}/chat", json={"question": question_text})
                http_status = r.status_code
                resp_json = r.json()
        except Exception as exc:
            exception = str(exc)

        wall_ms = round((time.monotonic() - wall_start) * 1000, 1)
        scores = score_response(q, resp_json, exception)

        record = {
            "id": qid,
            "pass": pass_num,
            "question": question_text,
            "expected_route": q.get("expected_route"),
            "expect_abstain": q.get("expect_abstain"),
            "expect_no_data": q.get("expect_no_data", False),
            "http_status": http_status,
            "wall_ms": wall_ms,
            "exception": exception,
            "response": resp_json,
            "scores": scores,
        }
        results.append(record)

    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--api-url", default="http://localhost:8000")
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("--passes", type=int, default=2)
    args = parser.parse_args()

    if not QUESTIONS_FILE.exists():
        print(f"ERROR: {QUESTIONS_FILE} not found.")
        sys.exit(1)

    questions = [json.loads(l) for l in QUESTIONS_FILE.read_text(encoding="utf-8").splitlines() if l.strip()]
    print(f"Loaded {len(questions)} questions.")

    # Health check
    try:
        with httpx.Client(timeout=10) as client:
            h = client.get(f"{args.api_url}/health")
            assert h.json().get("ok"), "health check failed"
        print(f"✅ API at {args.api_url} is healthy.")
    except Exception as exc:
        print(f"ERROR: Cannot reach API at {args.api_url}: {exc}")
        sys.exit(1)

    all_results = []
    for pass_num in range(1, args.passes + 1):
        print(f"\n{'='*60}\nPass {pass_num} of {args.passes}\n{'='*60}")
        pass_results = run_pass(questions, args.api_url, args.timeout, pass_num)
        all_results.extend(pass_results)

    # Write all results
    with RESULTS_FILE.open("w", encoding="utf-8") as f:
        for r in all_results:
            f.write(json.dumps(r, default=str, ensure_ascii=False) + "\n")
    print(f"\n✅ Results written to {RESULTS_FILE} ({len(all_results)} records)")

    # Stability check: questions with different routes or abstain across passes
    if args.passes >= 2:
        print("\n--- Stability Check (questions with different routes across passes) ---")
        pass1 = {r["id"]: r for r in all_results if r["pass"] == 1}
        pass2 = {r["id"]: r for r in all_results if r["pass"] == 2}
        unstable = []
        for qid, r1 in pass1.items():
            r2 = pass2.get(qid)
            if r2:
                route1 = (r1.get("response") or {}).get("route")
                route2 = (r2.get("response") or {}).get("route")
                abstain1 = bool((r1.get("response") or {}).get("abstain_reason"))
                abstain2 = bool((r2.get("response") or {}).get("abstain_reason"))
                if route1 != route2 or abstain1 != abstain2:
                    unstable.append({
                        "id": qid,
                        "pass1_route": route1, "pass2_route": route2,
                        "pass1_abstain": abstain1, "pass2_abstain": abstain2,
                    })
        if unstable:
            print(f"⚠️  {len(unstable)} unstable questions:")
            for u in unstable:
                print(f"  {u['id']}: route {u['pass1_route']}→{u['pass2_route']}, "
                      f"abstain {u['pass1_abstain']}→{u['pass2_abstain']}")
        else:
            print("✅ All questions stable across both passes.")

    # Quick summary
    print("\n--- Quick Score Summary (pass 1) ---")
    p1 = [r for r in all_results if r["pass"] == 1]
    total = len(p1)
    for key in ["route_correct", "abstain_correct", "no_data_correct",
                "no_demo_leak", "sql_safe", "retry_ok", "numeric_grounded",
                "numeric_correct", "source_cited"]:
        vals = [r["scores"].get(key) for r in p1 if r["scores"].get(key) is not None]
        if vals:
            pct = sum(1 for v in vals if v) / len(vals) * 100
            print(f"  {key}: {pct:.0f}% ({sum(1 for v in vals if v)}/{len(vals)})")


if __name__ == "__main__":
    main()
