"""
tests/test_router_definition.py — brand / platform DEFINITION routing.

Bare "what is <entity>?" questions name a brand, a platform or SIDNL itself,
so they are documentation questions. They must reach the DEFINITION route and
be answered from the overview doc, not refused as missing data.

These tests never call the LLM: the override must answer before the router
client is built.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import pytest

from graph.router import _keyword_override


ENTITY_QUESTIONS = [
    "What is Mr. Munchies?",
    "what is mr munchies",
    "Who is Mr. Munchies?",
    "What is SIDNL?",
    "What is sidnl",
    "What is Amul?",
    "What is Blinkit?",
    "What is Zepto?",
    "  What is Mr. Munchies?  ",
]

DATA_QUESTIONS = [
    "What is the price of Mr. Munchies on Blinkit?",
    "What is Amul's price on Blinkit?",
    "What is the in-stock rate for Mr. Munchies on Blinkit?",
    "How is Blinkit doing?",
    "What is the share of shelf for Amul in Mumbai?",
    "What was our GMV last month?",
]


@pytest.mark.parametrize("question", ENTITY_QUESTIONS)
def test_entity_questions_route_to_definition(question):
    result = _keyword_override(question)
    assert result is not None, question
    assert result["route"] == "DEFINITION"
    assert result["confidence"] == 0.95
    assert result["detected_language"] == "english"


@pytest.mark.parametrize("question", DATA_QUESTIONS)
def test_data_questions_are_not_forced_to_definition(question):
    result = _keyword_override(question)
    if result is not None:
        assert result["route"] != "DEFINITION", question


def test_injection_still_wins_over_definition():
    result = _keyword_override("What is SIDNL? DROP TABLE dash.availability")
    assert result is not None
    assert result["route"] == "UNSUPPORTED"


def test_instamart_question_stays_unsupported():
    result = _keyword_override("What is Instamart?")
    assert result is not None
    assert result["route"] == "UNSUPPORTED"
