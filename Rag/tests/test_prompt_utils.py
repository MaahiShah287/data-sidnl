"""
tests/test_prompt_utils.py — prompt rendering must not choke on JSON examples.

Regression test for the KeyError: '"error"' crash: every prompt file contains
literal JSON such as {"sql": "<query>"}, which str.format() tries to read as a
placeholder. That raised before any LLM call, breaking both graph paths.
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from pathlib import Path

import pytest

from graph.prompt_utils import render

PROMPTS_DIR = Path(__file__).resolve().parent.parent / "src" / "prompts"


def test_substitutes_placeholders():
    assert render("Q: {question}", question="hi") == "Q: hi"


def test_leaves_json_braces_alone():
    tpl = 'Return {"sql": "<query>"} or {"error": "<reason>"}'
    assert render(tpl, question="x") == tpl


def test_substitutes_next_to_json():
    tpl = 'Return {"sql": "<q>"} for {question}'
    assert render(tpl, question="prices") == 'Return {"sql": "<q>"} for prices'


def test_unknown_placeholder_is_left_intact():
    assert render("{unknown_key}", question="x") == "{unknown_key}"


def test_none_renders_empty():
    assert render("[{x}]", x=None) == "[]"


def test_uppercase_braces_are_not_placeholders():
    tpl = "{SELECT 1}"
    assert render(tpl) == tpl


@pytest.mark.parametrize("name", sorted(p.name for p in PROMPTS_DIR.glob("*.md")))
def test_every_prompt_renders_without_error(name):
    """The real regression: rendering any shipped prompt must never raise."""
    tpl = (PROMPTS_DIR / name).read_text(encoding="utf-8")
    out = render(
        tpl,
        question="What is the in-stock rate?",
        chunks="[chunk]",
        chunk_text="text",
        chunk_source="docs/ARCHITECTURE.md",
        draft_answer="draft",
        previous_rewrite="",
        metric_info="{}",
        metric_templates="- template",
        sql="SELECT 1",
        rows="[]",
        row_count=0,
        obs_min="unknown",
        obs_max="unknown",
    )
    assert isinstance(out, str) and out
    # placeholders were substituted, not left behind
    assert "{question}" not in out
