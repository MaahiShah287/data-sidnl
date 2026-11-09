"""Two smoke tests against the live silver DB. Skipped without SUPABASE_DB_URL.
Run: python -m unittest discover -s tests -v
"""
import os, unittest


def _connect():
    from sidnl.common import connect
    return connect()


@unittest.skipUnless(os.environ.get("SUPABASE_DB_URL"), "SUPABASE_DB_URL not set")
class SilverSmoke(unittest.TestCase):
    def test_parser_selftest(self):
        conn = _connect()
        try:
            with conn.cursor() as cur:
                cur.execute("select silver.selftest_parser()")
                self.assertEqual(cur.fetchone()[0], "all parser tests passed")
        finally:
            conn.close()

    def test_every_row_has_a_sidnl_id(self):
        """Bronze -> silver is automatic; every product, reading and shelf row must resolve to a SI id."""
        conn = _connect()
        try:
            with conn.cursor() as cur:
                for table in ("dim_product", "fact_product_reading", "fact_shelf_position"):
                    cur.execute(
                        f"select count(*) from silver.{table} t "
                        "left join silver.product_xref x using (product_key) where x.sidnl_id is null")
                    self.assertEqual(cur.fetchone()[0], 0, f"{table} has rows without a sidnl_id")
        finally:
            conn.close()


if __name__ == "__main__":
    unittest.main()
