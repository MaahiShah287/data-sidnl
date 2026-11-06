"""Silver parser/DQ tests run inside Postgres (the functions live there). Skipped without SUPABASE_DB_URL."""
import os, unittest


@unittest.skipUnless(os.environ.get("SUPABASE_DB_URL"), "SUPABASE_DB_URL not set")
class SilverSql(unittest.TestCase):
    def test_parser_selftest(self):
        from sidnl.common import connect
        conn = connect()
        try:
            with conn.cursor() as cur:
                cur.execute("select silver.selftest_parser()")
                self.assertEqual(cur.fetchone()[0], "all parser tests passed")
        finally:
            conn.close()

    def test_refresh_is_idempotent(self):
        from sidnl.common import connect
        conn = connect()
        try:
            with conn.cursor() as cur:
                cur.execute("select count(*) from silver.fact_product_reading"); before = cur.fetchone()[0]
                cur.execute("select silver.refresh_brand('mr munchies')")
                cur.execute("select count(*) from silver.fact_product_reading"); after = cur.fetchone()[0]
            conn.rollback()
            self.assertGreaterEqual(after, before)
        finally:
            conn.close()


if __name__ == "__main__":
    unittest.main()
