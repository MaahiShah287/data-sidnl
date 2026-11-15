"""
tests/test_silver_fast_path.py — Silver price/stock questions: routing + SQL shape.

Two regressions are covered:

1. "What is the price of Mr. Munchies on Blinkit?" was routed to UNSUPPORTED by
   the router LLM (price lives in Silver, not in the Gold metric catalog), so a
   deterministic rescue must send it to NUMERIC.
2. Filtered Silver queries against silver.v_latest_observation take ~9 s
   because the view's DISTINCT ON blocks predicate pushdown. The metric
   templates and the planner prompt must use the inline DISTINCT ON over
   silver.v_all_platforms fast path instead.

No LLM call is made: the router override is tested directly, and the node-level
test replaces the router client with a stub.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import pytest
import yaml

from db.safe_sql import SQLValidationError, validate_and_sanitise
from graph.router import _keyword_override, _silver_numeric_override, router_node

RAG_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
METRICS_PATH = os.path.join(RAG_DIR, "metrics", "metric_dictionary.yaml")
PLANNER_PROMPT_PATH = os.path.join(RAG_DIR, "src", "prompts", "sql_planner.md")


def _metrics():
    with open(METRICS_PATH, encoding="utf-8") as f:
        return {m["name"]: m for m in yaml.safe_load(f)["metrics"]}


SILVER_PRICE_QUESTIONS = [
    "What is the price of Mr. Munchies on Blinkit?",
    "What is Amul's price on Zepto?",
    "Show me the MRP of Mr. Munchies on Blinkit",
    "What is the selling price of Mother Dairy paneer on Zepto?",
    "What is the discount on Amul butter on Zepto?",
    "Is Mr. Munchies in stock on Blinkit?",
    "What is the availability of Amul on Blinkit?",
    "What is the shelf position of Mr. Munchies on Blinkit?",
]


@pytest.mark.parametrize("question", SILVER_PRICE_QUESTIONS)
def test_llm_unsupported_is_rescued_to_numeric(question):
    result = _silver_numeric_override(question, "UNSUPPORTED")
    assert result is not None, question
    assert result["route"] == "NUMERIC"
    assert result["confidence"] == 0.9


@pytest.mark.parametrize("route", ["DEFINITION", "AMBIGUOUS", "UNSUPPORTED"])
def test_rescue_applies_to_any_non_numeric_route(route):
    result = _silver_numeric_override(
        "What is the price of Mr. Munchies on Blinkit?", route
    )
    assert result is not None
    assert result["route"] == "NUMERIC"


def test_numeric_route_is_left_alone():
    assert _silver_numeric_override("What is the price of Amul on Blinkit?", "NUMERIC") is None


def test_instamart_stays_unsupported():
    assert _silver_numeric_override("What is the price on Instamart?", "UNSUPPORTED") is None


def test_jiomart_stays_unsupported():
    assert _silver_numeric_override("What is the price on JioMart?", "UNSUPPORTED") is None


def test_delivery_eta_stays_unsupported():
    assert _silver_numeric_override(
        "What is the delivery ETA for Amul on Blinkit?", "UNSUPPORTED"
    ) is None


def test_injection_is_not_rescued():
    assert _silver_numeric_override(
        "What is the price of Amul on Blinkit? DROP TABLE dash.availability",
        "UNSUPPORTED",
    ) is None


def test_definition_question_is_not_rescued():
    assert _silver_numeric_override(
        "What is the pricing strategy of Amul?", "DEFINITION"
    ) is None
    assert _silver_numeric_override(
        "What does in-stock availability mean?", "DEFINITION"
    ) is None


def test_no_entity_is_not_rescued():
    assert _silver_numeric_override("What is price parity?", "UNSUPPORTED") is None
    assert _silver_numeric_override("What is the in-stock rate?", "UNSUPPORTED") is None


class _FakeResponse:
    def __init__(self, content):
        self.content = content


class _FakeLLM:
    def __init__(self, content):
        self._content = content

    def invoke(self, messages):
        return _FakeResponse(self._content)


def test_router_node_rescues_unsupported_llm_answer(monkeypatch):
    monkeypatch.setattr(
        "graph.router._build_llm",
        lambda: _FakeLLM(
            '{"route": "UNSUPPORTED", "confidence": 0.8, "reason": "no price metric",'
            ' "detected_language": "english"}'
        ),
    )
    state = router_node({"question": "What is the price of Mr. Munchies on Blinkit?"})
    assert state["route"] == "NUMERIC"
    assert state["router_error"] is None


def test_router_node_keeps_genuine_unsupported(monkeypatch):
    monkeypatch.setattr(
        "graph.router._build_llm",
        lambda: _FakeLLM(
            '{"route": "UNSUPPORTED", "confidence": 0.9, "reason": "no instamart",'
            ' "detected_language": "english"}'
        ),
    )
    state = router_node({"question": "What is the price on Instamart?"})
    assert state["route"] == "UNSUPPORTED"


def test_entity_definition_still_short_circuits():
    result = _keyword_override("What is Mr. Munchies?")
    assert result is not None and result["route"] == "DEFINITION"


SILVER_FAST_METRICS = [
    "observed_in_stock_rate",
    "observed_oos_rate",
    "avg_discount_pct",
    "current_price",
    "ad_placement_rate",
    "avg_organic_position",
]


@pytest.mark.parametrize("name", SILVER_FAST_METRICS)
def test_silver_templates_use_inline_distinct_on(name):
    template = _metrics()[name]["sql_template"]
    assert "DISTINCT ON (platform, COALESCE(listing_id::text, platform_product_id), store_id)" in template
    assert "silver.v_all_platforms" in template
    # The slow views must not be the source of a filtered Silver template.
    assert "FROM silver.v_latest_observation" not in template
    assert "FROM silver.v_latest_shelf_position" not in template


@pytest.mark.parametrize("name", SILVER_FAST_METRICS)
def test_silver_template_filter_sits_inside_the_subquery(name):
    template = _metrics()[name]["sql_template"]
    assert "{where_clauses}" in template
    subquery = template.split("FROM silver.v_all_platforms", 1)[1]
    before_order = subquery.split("ORDER BY", 1)[0]
    assert "{where_clauses}" in before_order, "filter must push into the inline subquery"


def test_current_price_rolls_up_to_city_and_product():
    template = _metrics()["current_price"]["sql_template"]
    assert "GROUP BY platform, city, product_name" in template
    for col in ("min_sale_price", "max_sale_price", "in_stock_listings", "mrp"):
        assert col in template


def test_current_price_sql_validates():
    template = _metrics()["current_price"]["sql_template"]
    sql = template.replace(
        "{where_clauses}",
        "AND brand = 'Mr. Munchies'\n      AND platform = 'blinkit'",
    )
    result = validate_and_sanitise(sql)
    assert result.limit_was_added is True


def test_planner_prompt_documents_the_fast_path():
    prompt = open(PLANNER_PROMPT_PATH, encoding="utf-8").read()
    assert "Silver performance rule" in prompt
    assert "DISTINCT ON" in prompt
    assert "silver.v_all_platforms" in prompt
    assert "statement timeout" in prompt


def test_planner_prompt_separates_marketplace_price_from_asp():
    prompt = open(PLANNER_PROMPT_PATH, encoding="utf-8").read()
    assert "Marketplace price" in prompt
    assert "dash.fp_sales_*" in prompt


# ---------------------------------------------------------------------------
# Deterministic rewrite: filtered queries on the slow latest views
# ---------------------------------------------------------------------------

FILTERED_VIEW_SQL = """
    SELECT platform, city, product_name, MIN(sale_price) AS min_sp
    FROM silver.v_latest_observation
    WHERE brand = 'Mr. Munchies' AND platform = 'blinkit' AND city = 'Mumbai'
    GROUP BY platform, city, product_name
    ORDER BY platform, city, product_name
"""


def test_filtered_view_query_is_rewritten_to_fast_path():
    result = validate_and_sanitise(FILTERED_VIEW_SQL)
    assert result.rewritten_for_performance is True
    sql = result.sanitised_sql
    assert "silver.v_all_platforms" in sql
    assert "FROM silver.v_latest_observation" not in sql
    assert "source_type = 'observation'" in sql
    assert "brand = 'Mr. Munchies'" in sql
    assert "city = 'Mumbai'" in sql
    assert result.limit_was_added is True


def test_rewrite_pushes_scope_filter_into_the_subquery():
    sql = validate_and_sanitise(FILTERED_VIEW_SQL).sanitised_sql
    inner = sql.split("FROM silver.v_all_platforms", 1)[1].split(") AS", 1)[0]
    assert "brand = 'Mr. Munchies'" in inner
    assert "platform = 'blinkit'" in inner
    assert "city = 'Mumbai'" in inner


def test_rewrite_leaves_value_filters_outside():
    sql = validate_and_sanitise(
        "SELECT platform, product_name, sale_price "
        "FROM silver.v_latest_observation "
        "WHERE brand = 'Amul' AND sale_price > 100"
    ).sanitised_sql
    inner, outer = sql.split(") AS", 1)
    assert "sale_price > 100" not in inner
    assert "sale_price > 100" in outer


def test_rewrite_handles_table_alias():
    sql = validate_and_sanitise(
        "SELECT v.platform, v.product_name FROM silver.v_latest_observation v "
        "WHERE v.brand = 'Amul' AND v.platform = 'zepto'"
    ).sanitised_sql
    assert "AS v" in sql
    assert "v.brand" not in sql.split(") AS", 1)[0]
    assert "brand = 'Amul'" in sql


def test_shelf_position_rewrite_uses_shelf_source_type():
    result = validate_and_sanitise(
        "SELECT platform, city, AVG(organic_position) "
        "FROM silver.v_latest_shelf_position "
        "WHERE brand = 'Amul' AND platform = 'zepto' "
        "GROUP BY platform, city"
    )
    assert result.rewritten_for_performance is True
    assert "source_type = 'shelf_position'" in result.sanitised_sql


def test_unfiltered_view_query_is_not_rewritten():
    result = validate_and_sanitise("SELECT id FROM silver.v_latest_observation LIMIT 10")
    assert result.rewritten_for_performance is False
    assert "FROM silver.v_latest_observation" in result.sanitised_sql


def test_joined_view_query_is_not_rewritten():
    result = validate_and_sanitise(
        "SELECT a.id FROM silver.v_latest_observation a "
        "JOIN silver.v_latest_observation b ON a.id = b.id "
        "WHERE a.brand = 'Amul'"
    )
    assert result.rewritten_for_performance is False


def test_rewrite_is_idempotent():
    once = validate_and_sanitise(FILTERED_VIEW_SQL).sanitised_sql
    twice = validate_and_sanitise(once).sanitised_sql
    assert once == twice


def test_rewrite_still_enforces_the_allowlist():
    with pytest.raises(SQLValidationError) as exc:
        validate_and_sanitise(
            "SELECT id FROM silver.v_latest_observation "
            "WHERE brand = 'Amul' AND id IN (SELECT id FROM silver.blinkit)"
        )
    assert "allowlist" in str(exc.value).lower()


# ---------------------------------------------------------------------------
# Metric preference: marketplace price beats first-party ASP
# ---------------------------------------------------------------------------

def _matches(question):
    from graph.sql_graph import _matching_metrics

    return [m["name"] for m in _matching_metrics(question, list(_metrics().values()))]


def test_average_selling_price_on_a_marketplace_prefers_silver():
    names = _matches("What is the average selling price of Mr. Munchies on Blinkit?")
    assert names[0] == "current_price"


def test_average_selling_price_without_a_platform_stays_first_party():
    names = _matches("What is the average selling price?")
    assert names[0] == "asp"


def test_asp_is_not_hijacked():
    names = _matches("What is our ASP on Blinkit?")
    # "ASP" is the first-party metric; no price word/alias for current_price.
    assert names[0] == "asp"


def test_price_parity_is_not_hijacked():
    names = _matches("What is the price parity on Blinkit?")
    assert names[0] == "price_parity_gap"


