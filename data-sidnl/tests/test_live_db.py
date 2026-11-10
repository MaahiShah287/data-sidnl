"""Tests against the live database. Skipped without SUPABASE_DB_URL.

    python -m unittest discover -s tests -v

Every fault test runs inside a transaction that is rolled back, injects the fault by replacing a function or changing a
threshold (never by inserting rows), and checks that the database is unchanged afterwards. No data is invented.
"""
import os
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import sidnl  # noqa: E402

LIVE = bool(os.environ.get("SUPABASE_DB_URL"))


def scalar(cur, sql, params=None):
    cur.execute(sql, params)
    return cur.fetchone()[0]


@unittest.skipUnless(LIVE, "SUPABASE_DB_URL not set")
class LiveDb(unittest.TestCase):
    def setUp(self):
        self.conn = sidnl.connect()
        self.cur = self.conn.cursor()

    def tearDown(self):
        self.conn.rollback()
        self.cur.close()
        self.conn.close()

    # ---------------------------------------------------------------- smoke
    def test_parser_selftest(self):
        self.assertEqual(scalar(self.cur, "select silver.selftest_parser()"), "all parser tests passed")

    def test_matcher_selftest(self):
        self.assertEqual(scalar(self.cur, "select count(*) from silver.selftest_matcher() t where not t.ok"), 0)

    def test_quality_checks(self):
        self.assertEqual(scalar(self.cur, "select count(*) from silver.quality_checks() t where not t.ok"), 0)

    def test_every_row_has_a_sidnl_id(self):
        for table in ("dim_product", "fact_product_reading", "fact_shelf_position"):
            n = scalar(self.cur, f"select count(*) from silver.{table} t "
                                 "left join silver.product_xref x using (product_key) where x.sidnl_id is null")
            self.assertEqual(n, 0, f"{table} has rows without a sidnl_id")

    def test_all_cron_jobs_active(self):
        n = scalar(self.cur, "select count(*) from cron.job where jobname like 'sidnl-%' and not active")
        self.assertEqual(n, 0)

    # ---------------------------------------------------------------- bronze -> silver -> dash
    def test_reconciliation_latest_ok(self):
        self.cur.execute("select check_name, status, mismatches from ops.v_reconciliation_latest")
        for name, status, bad in self.cur.fetchall():
            self.assertIn(status, ("ok", "skipped"), f"{name}: {status} ({bad} mismatches)")

    def test_repo_schema_matches_live(self):
        for path, text in sidnl.render(self.conn).items():
            have = path.read_text(encoding="utf-8").replace("\r\n", "\n")
            self.assertEqual(have, text, f"{path.name} differs from the live database: run `python sidnl.py export-schema`")

    # ---------------------------------------------------------------- scenario 6: dash.refresh fails
    def test_gold_failure_is_retried_and_keeps_old_data(self):
        c = self.cur
        before = scalar(c, "select count(*) from dash.pricing")
        md5 = scalar(c, "select md5(pg_get_functiondef('dash.refresh(integer)'::regprocedure))")
        c.execute("""create or replace function dash.refresh(p_visibility_days integer default 3) returns jsonb
                     language plpgsql as $f$ begin raise exception using errcode = '40001', message = 'injected'; end $f$""")
        c.execute("update ops.pipeline_run set gold_status = 'pending' "
                  "where run_id = (select max(run_id) from ops.pipeline_run where status = 'success')")
        res = scalar(c, "select silver.run_gold_pending()")
        self.assertEqual(res["status"], "failed")
        self.assertEqual(res["error_class"], "transient")
        self.assertIsNotNone(res["next_attempt_at"])
        self.assertEqual(scalar(c, "select count(*) from dash.pricing"), before, "old dash rows must stay")
        self.assertTrue(scalar(c, "select bool_and(refresh_failing) from dash.v_refresh_status"))
        self.conn.rollback()
        self.assertEqual(scalar(c, "select md5(pg_get_functiondef('dash.refresh(integer)'::regprocedure))"), md5)

    # ---------------------------------------------------------------- scenario 9: a platform goes stale
    def test_lowered_threshold_flags_stale_and_clears(self):
        c = self.cur
        c.execute("select platform from dash.v_data_freshness where source_type = 'category_shelf' and status = 'fresh' limit 1")
        row = c.fetchone()
        if row is None:
            self.skipTest("no platform has fresh category-shelf data right now")
        platform = row[0]
        c.execute("insert into ops.freshness_override (platform, source_type, fresh_within_hours, note) "
                  "values (%s, 'category_shelf', 0, 'test')", (platform,))
        scalar(c, "select silver.refresh_freshness()")
        self.assertEqual(scalar(c, "select status from dash.v_data_freshness where platform = %s "
                                   "and source_type = 'category_shelf'", (platform,)), "stale")
        c.execute("delete from ops.freshness_override where note = 'test'")
        scalar(c, "select silver.refresh_freshness()")
        self.assertEqual(scalar(c, "select status from dash.v_data_freshness where platform = %s "
                                   "and source_type = 'category_shelf'", (platform,)), "fresh")
        self.conn.rollback()
        self.assertEqual(scalar(c, "select count(*) from ops.freshness_override where note = 'test'"), 0)


if __name__ == "__main__":
    unittest.main()
