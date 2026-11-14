"""
tests/test_safe_sql.py — 49 unit tests for src/db/safe_sql.py (restored).
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import pytest
from db.safe_sql import (
    ALLOWLISTED_RELATIONS, DEFAULT_LIMIT, SQLValidationError,
    SafeResult, validate_and_sanitise, validate_and_sanitise_safe,
)

def _ok(sql):
    result = validate_and_sanitise(sql)
    assert isinstance(result, SafeResult)
    return result

def _bad(sql, fragment=""):
    with pytest.raises(SQLValidationError) as exc_info:
        validate_and_sanitise(sql)
    err = str(exc_info.value)
    if fragment:
        assert fragment.lower() in err.lower(), f"Expected '{fragment}' in: {err}"
    return err

class TestWritesBlocked:
    def test_insert_blocked(self):        _bad("INSERT INTO silver.v_latest_observation (id) VALUES ('x')", "INSERT")
    def test_update_blocked(self):        _bad("UPDATE silver.v_latest_observation SET availability=true WHERE id='1'", "UPDATE")
    def test_delete_blocked(self):        _bad("DELETE FROM silver.v_latest_observation WHERE id='1'", "DELETE")
    def test_drop_blocked(self):          _bad("DROP TABLE silver.blinkit", "DROP")
    def test_alter_blocked(self):         _bad("ALTER TABLE silver.blinkit ADD COLUMN x int", "ALTER")
    def test_create_blocked(self):        _bad("CREATE TABLE hack AS SELECT 1", "CREATE")
    def test_grant_blocked(self):         _bad("GRANT ALL ON silver.blinkit TO public", "GRANT")
    def test_copy_blocked(self):          _bad("COPY silver.blinkit TO '/tmp/data.csv'", "COPY")
    def test_truncate_blocked(self):      _bad("TRUNCATE silver.blinkit", "TRUNCATE")
    def test_pg_sleep_blocked(self):      _bad("SELECT pg_sleep(10)", "pg_sleep")
    def test_execute_blocked(self):       _bad("EXECUTE my_plan", "EXECUTE")
    def test_call_blocked(self):          _bad("CALL some_proc()", "CALL")

class TestMultiStatementBlocked:
    def test_two_selects(self):           _bad("SELECT 1; SELECT 2")
    def test_select_then_drop(self):      _bad("SELECT id FROM silver.v_latest_observation; DROP TABLE silver.blinkit")
    def test_trailing_semicolon_ok(self):
        r = _ok("SELECT id FROM silver.v_latest_observation;")
        assert ";" not in r.sanitised_sql
    def test_semicolon_in_literal(self):  _bad("SELECT 'hello; world' FROM silver.v_latest_observation")

class TestNonAllowlistedRelations:
    def test_blinkit_blocked(self):       _bad("SELECT id FROM silver.blinkit", "not in the allowlist")
    def test_zepto_blocked(self):         _bad("SELECT id FROM silver.zepto", "not in the allowlist")
    def test_instamart_blocked(self):     _bad("SELECT id FROM silver.instamart", "not in the allowlist")
    def test_jiomart_blocked(self):       _bad("SELECT id FROM silver.jiomart", "not in the allowlist")
    def test_demo_blocked(self):          _bad("SELECT id FROM silver.demo", "not in the allowlist")
    def test_public_blocked(self):        _bad("SELECT id FROM public.users", "not in the allowlist")
    def test_unqualified_blocked(self):   _bad("SELECT id FROM blinkit", "not in the allowlist")
    def test_info_schema_blocked(self):   _bad("SELECT table_name FROM information_schema.tables", "not in the allowlist")
    def test_pg_catalog_blocked(self):    _bad("SELECT relname FROM pg_class", "not in the allowlist")
    def test_subquery_base_blocked(self):
        _bad("SELECT a.id FROM silver.v_latest_observation a JOIN (SELECT id FROM silver.blinkit) b ON a.id=b.id", "not in the allowlist")
    def test_cte_base_blocked(self):
        _bad("WITH x AS (SELECT id FROM silver.blinkit) SELECT * FROM x", "not in the allowlist")
    def test_demo_in_union_blocked(self):
        _bad("SELECT id FROM silver.v_all_platforms UNION ALL SELECT id FROM silver.demo", "not in the allowlist")

class TestLimitAutoAppend:
    def test_limit_added(self):
        r = _ok("SELECT id FROM silver.v_latest_observation")
        assert r.limit_was_added is True
        assert f"LIMIT {DEFAULT_LIMIT}" in r.sanitised_sql
    def test_limit_not_doubled(self):
        r = _ok("SELECT id FROM silver.v_latest_observation LIMIT 50")
        assert r.limit_was_added is False
        assert r.sanitised_sql.upper().count("LIMIT") == 1
    def test_limit_200_default(self):
        r = _ok("SELECT id FROM silver.v_latest_observation")
        assert f"LIMIT {DEFAULT_LIMIT}" in r.sanitised_sql
    def test_limit_1_preserved(self):
        r = _ok("SELECT id FROM silver.v_latest_observation LIMIT 1")
        assert r.limit_was_added is False

class TestValidQueriesAccepted:
    def test_v_all_platforms(self):       assert _ok("SELECT platform, COUNT(*) FROM silver.v_all_platforms GROUP BY platform")
    def test_v_latest_observation(self):  assert _ok("SELECT product_name, sale_price FROM silver.v_latest_observation WHERE brand='Test'")
    def test_v_latest_shelf(self):        assert _ok("SELECT platform, organic_position FROM silver.v_latest_shelf_position LIMIT 10")
    def test_cte_on_allowlisted(self):
        r = _ok("""
            WITH obs AS (SELECT platform, availability FROM silver.v_latest_observation)
            SELECT platform, COUNT(*) FILTER (WHERE availability) AS in_stock FROM obs GROUP BY platform
        """)
        assert r is not None
    def test_union_allowlisted(self):
        assert _ok("SELECT id,'obs' AS src FROM silver.v_latest_observation UNION ALL SELECT id,'shelf' AS src FROM silver.v_latest_shelf_position")
    def test_subquery_allowlisted(self):
        assert _ok("SELECT * FROM (SELECT platform, AVG(sale_price) AS avg FROM silver.v_latest_observation GROUP BY platform) sub")
    def test_trailing_semi_stripped(self):
        r = _ok("SELECT id FROM silver.v_latest_observation;")
        assert not r.sanitised_sql.strip().endswith(";")
    def test_empty_rejected(self):        _bad("", "empty")
    def test_whitespace_rejected(self):   _bad("   \n  ", "empty")

class TestSafeWrapper:
    def test_success(self):
        r, e = validate_and_sanitise_safe("SELECT id FROM silver.v_latest_observation")
        assert r is not None and e is None
    def test_failure(self):
        r, e = validate_and_sanitise_safe("DROP TABLE silver.blinkit")
        assert r is None and e is not None
    def test_error_is_string(self):
        _, e = validate_and_sanitise_safe("SELECT * FROM silver.demo")
        assert isinstance(e, str)

class TestEdgeCases:
    def test_comment_injection(self):     _bad("SELECT id FROM silver.v_latest_observation -- ; INSERT INTO silver.blinkit VALUES(1)")
    def test_case_insensitive(self):
        _bad("insert into silver.v_latest_observation values(1)", "INSERT")
        _bad("InSeRt INTO silver.v_latest_observation VALUES(1)", "INSERT")
    def test_pg_sleep_subquery(self):     _bad("SELECT (SELECT pg_sleep(5)) FROM silver.v_latest_observation", "pg_sleep")
    def test_dblink_blocked(self):        _bad("SELECT dblink('host=x','SELECT 1')", "dblink")
    def test_allowlist_complete(self):
        from db.safe_sql import (
            GOLD_DIMENSIONS, GOLD_TABLES, GOLD_VIEWS, SILVER_RELATIONS,
        )

        assert SILVER_RELATIONS == frozenset({
            "silver.v_all_platforms",
            "silver.v_latest_observation",
            "silver.v_latest_shelf_position",
        })
        assert ALLOWLISTED_RELATIONS == (
            SILVER_RELATIONS | GOLD_TABLES | GOLD_DIMENSIONS | GOLD_VIEWS
        )
        # Gold (dash) is part of the allowlist.
        assert "dash.availability" in ALLOWLISTED_RELATIONS
        assert "dash.metric_catalog" in ALLOWLISTED_RELATIONS
        assert "dash.v_chatbot_availability_city" in ALLOWLISTED_RELATIONS

    def test_gold_relations_accepted(self):
        assert _ok("SELECT osa_pct FROM dash.v_chatbot_availability_city")
        assert _ok("SELECT sum(gmv) FROM dash.v_fp_sales_day")
        assert _ok("SELECT count(*) FROM dash.metric_catalog")
        assert _ok(
            "SELECT a.osa_pct FROM dash.availability a "
            "JOIN dash.dim_city c ON c.city_slug = a.city_slug "
            "WHERE a.store_key IS NULL"
        )

    def test_gold_base_scraped_tables_still_blocked(self):
        _bad("SELECT * FROM silver.fact_product_reading", "not in the allowlist")
        _bad("SELECT * FROM silver.fact_store_scan", "not in the allowlist")
        _bad("SELECT * FROM app.tenants", "not in the allowlist")
