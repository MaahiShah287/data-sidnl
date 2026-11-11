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

    # ---------------------------------------------------------------- the in-database suite (silver_071)
    # One call covers parser, dq rules, matcher, SI-id integrity, the failed-read rule, the personal-data guard and
    # the cron jobs (it replaced 5 tests here that re-ran the same database checks). Every failure is listed.
    def test_selftest_suite(self):
        results = sidnl.run_selftest(self.conn)
        failed = [f"{s}/{t}: {d}" for s, t, ok, d in results if not ok]
        self.assertGreater(len(results), 0)
        self.assertEqual(failed, [], "\n".join(failed))

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

    # ---------------------------------------------------------------- scenario 13: heartbeat endpoint
    def test_heartbeat_requires_token_and_reports_jobs(self):
        c = self.cur
        c.execute("select set_config('response.status', '', true)")
        res = scalar(c, "select public.sidnl_heartbeat(null)")
        self.assertEqual(res["ok"], False)
        self.assertEqual(res["error"], "unauthorized")
        self.assertEqual(scalar(c, "select current_setting('response.status', true)"), "401")
        self.assertEqual(scalar(c, "select count(*) from ops.heartbeat()"), scalar(c, "select count(*) from cron.job where jobname like 'sidnl-%'"))

    def test_heartbeat_flags_a_paused_job_and_restores(self):
        c = self.cur
        before = scalar(c, "select active from cron.job where jobname = 'sidnl-store-city'")
        c.execute("select cron.alter_job((select jobid from cron.job where jobname = 'sidnl-store-city'), active := false)")
        c.execute("select count(*) from ops.heartbeat() where jobname = 'sidnl-store-city' and not active")
        self.assertEqual(c.fetchone()[0], 1)
        self.conn.rollback()
        self.assertEqual(scalar(c, "select active from cron.job where jobname = 'sidnl-store-city'"), before)


if __name__ == "__main__":
    unittest.main()
