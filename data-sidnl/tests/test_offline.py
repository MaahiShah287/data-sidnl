"""Tests that need no database: run on every machine and in CI.

    python -m unittest discover -s tests -v

They pin the bronze -> silver column contract ("Bronze -> Silver: which columns to carry", 2026-11-10) to the pending
migrations, check every pending migration has a rollback and parses as PostgreSQL (when pglast is installed), and
check the command line's retry and ordering logic.
"""
import os
import pathlib
import importlib.util
import re
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import sidnl  # noqa: E402

PENDING = sidnl.PENDING_DIR


def sql(name):
    return (PENDING / name).read_text(encoding="utf-8")


def all_pending_sql():
    return "\n".join(p.read_text(encoding="utf-8") for p in sidnl.pending_files())


# bronze table -> columns the doc says to carry, each with the silver column that must receive it
CARRY = {
    "observations.details.max_allowed_quantity": "max_allowed_quantity",
    "observations.details.pack_size": "pack_size_seen",
    "observations.details.store_role": "store_role",
    "search_cards.matched_by": "matched_by",
    "search_cards.variant_of": "variant_of",
    "search_snapshots.query": "search_query",
    "search_snapshots.lat": "latitude",
    "search_snapshots.error": "scan_error",
    "shelf_snapshots.sweep_id": "sweep_id",
    "shelf_snapshots.category_name": "category_name",
    "shelf_snapshots.error": "read_error",
    "check_points.serviceable": "is_serviceable",
    "coverage.resolved_at": "observed_at",
    "sample_points.pincode": "pincode",
    "fulfilment_probes.location_verified": "location_verified",
    "products.org_id": "org_id",
    "platform_listings.details.brand_id": "brand_id",
    "platform_listings.details.l3_category_ids": "l3_category_ids",
    "check_runs.blocked": "blocked",
    "category_sweeps.stores_skipped": "stores_skipped",
    "brand_scrapes.products_found": "products_found",
    "platform_products.id": "source_product_id",
}

# columns the doc says stay in bronze: no pending migration may load them into silver
LEAVE = ["pages_read", "elapsed_ms", "backend", "rating_count", "meta_status", "meta_elapsed_ms", "heartbeat_at",
         "max_cards", "rate_per_min", "concurrency", "candidates", "diagnostics", "evidence_path"]

NEVER_COPY = ["demo_requests", "organizations", "workspace_members", "alembic_version", "listing_snapshots",
              "brand_logos", "fetch_runs", "platform_state"]


class ColumnContract(unittest.TestCase):
    def test_every_carried_column_has_a_silver_column(self):
        text = all_pending_sql()
        for bronze, col in CARRY.items():
            with self.subTest(bronze=bronze):
                self.assertRegex(text, rf"(?m)(add column if not exists |^\s+){re.escape(col)}\s+\w",
                                 f"{bronze}: silver column {col} is never created")

    def test_left_in_bronze_is_never_loaded(self):
        # only code (not comments) counts
        code = re.sub(r"--[^\n]*", "", all_pending_sql())
        for col in LEAVE:
            with self.subTest(col=col):
                self.assertNotRegex(code, rf"\b\w+\.{col}\b", f"{col} must stay in bronze")

    def test_never_copied_tables(self):
        code = re.sub(r"--[^\n]*", "", all_pending_sql())
        for t in NEVER_COPY:
            with self.subTest(table=t):
                # the self-test may name demo_requests to check nothing reads it; nothing may select from it
                self.assertNotRegex(code, rf"from\s+public\.{t}\b|join\s+public\.{t}\b")

    def test_failed_reads_never_out_of_stock(self):
        text = sql("silver_069_bronze_column_contract.sql")
        # both loaders route the stock state through read_stock_status before quality flags are computed
        self.assertEqual(text.count("silver.read_stock_status(silver.map_stock_status("), 3)   # 2 loaders + backfill
        self.assertEqual(text.count("|| silver.read_flags("), 4)   # 2 loaders + backfill (readings, shelf)
        self.assertIn("'read_failed'] then 'invalid'", text)
        self.assertIn("'read_incomplete'] then 'suspect'", text)


class PendingMigrations(unittest.TestCase):
    def test_order_lists_existing_files(self):
        files = sidnl.pending_files()
        self.assertGreater(len(files), 0)
        for f in files:
            self.assertTrue(f.exists(), f)
        names = [f.name for f in files]
        self.assertLess(names.index("silver_070_scrape_context.sql"), names.index("dash_011_coverage_collection.sql"))
        self.assertLess(names.index("silver_069_bronze_column_contract.sql"), names.index("silver_071_essential_selftest.sql"))

    def test_every_migration_has_a_rollback(self):
        rb = sql("rollbacks_pending.sql")
        for f in sidnl.pending_files():
            mig = f.stem.split("_")[0] + "_" + f.stem.split("_")[1]
            self.assertIn(f"rollback {mig}", rb, f"{f.name} has no rollback block")

    def test_bronze_columns_checked_before_any_change(self):
        for name in ("silver_069_bronze_column_contract.sql", "silver_070_scrape_context.sql"):
            text = sql(name)
            self.assertLess(text.index("preflight"), text.index("alter table") if "alter table" in text
                            else text.index("create table"), name)

    @unittest.skipUnless(importlib.util.find_spec("pglast"), "pglast not installed (pip install pglast)")
    def test_migrations_parse_as_postgresql(self):
        from pglast import parser
        for f in sidnl.pending_files():
            with self.subTest(f=f.name):
                text = f.read_text(encoding="utf-8")
                parser.parse_sql(text)
                parser.parse_plpgsql_json(text)


class Cli(unittest.TestCase):
    def test_connect_retries_transient_errors_then_succeeds(self):
        conn = mock.MagicMock()
        calls = {"n": 0}

        def flaky(_url):
            calls["n"] += 1
            if calls["n"] < 3:
                raise OSError("server closed the connection unexpectedly")
            return conn

        with mock.patch.dict(os.environ, {"SUPABASE_DB_URL": "postgresql://x"}), \
             mock.patch.object(sidnl, "_open", side_effect=flaky), \
             mock.patch.object(sidnl.time, "sleep") as slept:
            self.assertIs(sidnl.connect(), conn)
        self.assertEqual(calls["n"], 3)
        self.assertEqual([c.args[0] for c in slept.call_args_list], [2, 4])

    def test_connect_gives_up_on_bad_password_at_once(self):
        with mock.patch.dict(os.environ, {"SUPABASE_DB_URL": "postgresql://x"}), \
             mock.patch.object(sidnl, "_open", side_effect=OSError('password authentication failed for user "x"')), \
             mock.patch.object(sidnl.time, "sleep") as slept:
            with self.assertRaises(SystemExit):
                sidnl.connect()
        slept.assert_not_called()

    def test_connect_without_url_exits(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(SystemExit):
                sidnl.connect()


if __name__ == "__main__":
    unittest.main()
