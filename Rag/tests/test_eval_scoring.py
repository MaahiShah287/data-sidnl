"""
tests/test_eval_scoring.py - unit tests for eval/run_eval.py scoring.

These lock in two behaviours that silently corrupt a baseline:
  * bookkeeping numbers (row counts, dates, SQL, draft-banner constants) must
    not be treated as metric claims;
  * an `expect_no_data` question must pass only when the bot abstains.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "eval"))

from run_eval import _scoring_numbers, score_response  # noqa: E402


def test_scoring_numbers_ignores_bookkeeping():
    text = (
        "Draft metric: a / b * 100\n"
        "The in-stock rate is 7.6% across 1 row (observed 2026-11-10).\n"
        "```sql\nSELECT * FROM t LIMIT 200\n```"
    )
    assert _scoring_numbers(text) == {7.6}


def test_row_count_does_not_flag_hallucination():
    q = {"expected_route": "NUMERIC"}
    resp = {
        "route": "NUMERIC",
        "answer": "The average sale price is 170.15 across 1 row.",
        "rows": [{"avg_sale_price": 170.15}],
    }
    scores = score_response(q, resp, None)
    assert scores["numeric_grounded"] is True
    assert scores["hallucination"] is False


def test_ungrounded_number_flags_hallucination():
    q = {"expected_route": "NUMERIC"}
    resp = {
        "route": "NUMERIC",
        "answer": "The average sale price is 999.0.",
        "rows": [{"avg_sale_price": 170.15}],
    }
    assert score_response(q, resp, None)["hallucination"] is True


def test_no_data_question_fails_when_it_answers():
    q = {"expected_route": "NUMERIC", "expect_no_data": True}
    resp = {
        "route": "NUMERIC",
        "answer": "The in-stock rate is 7.6%.",
        "abstain_reason": None,
        "rows": [{"in_stock_pct": 7.6}],
    }
    scores = score_response(q, resp, None)
    assert scores["no_data_correct"] is False
    assert scores["abstain_correct"] is False


def test_no_data_question_passes_when_it_abstains():
    q = {"expected_route": "NUMERIC", "expect_no_data": True}
    resp = {
        "route": "NUMERIC",
        "answer": "No matching observations found for the given filters.",
        "abstain_reason": "No matching observations found.",
        "rows": [],
    }
    scores = score_response(q, resp, None)
    assert scores["no_data_correct"] is True
    assert scores["abstain_correct"] is True
