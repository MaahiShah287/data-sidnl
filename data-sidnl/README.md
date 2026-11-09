# SIDNL

Quick-commerce analytics on Supabase: **bronze** (`public`, raw scrapes, never touched) -> **silver** (only what metrics need)
-> **gold** (metrics) -> FastAPI / portal.

The pipeline runs inside the database (pg_cron every minute, `silver.run_tick()`); nothing has to be run by hand.
New bronze rows become silver rows, get a SI id, and flow on to gold automatically.

```
sidnl/    check/run helpers (cli.py, silver.py, common.py)
sql/      silver/ (numbered history + live/ dated migrations), gold/
docs/     silver/SILVER_SCHEMA.md, CANONICAL_MAP.md, SILVER_OPERATIONS.md
portal/   Next.js frontend (reads gold + the sidnl views)
tests/    two smoke tests
Rag/      RAG experiment (on hold)
```

## Everything is keyed by SI id
One real-world product = one `sidnl_id` on every platform, kept strictly **A-Z by product name** (`SI001` = first name alphabetically).
Because the order is kept alphabetical, adding a product shifts the ids after it; do not store SI ids outside the database
(store platform + platform_product_id instead).

```sql
select * from silver.v_sidnl_product;                         -- one row per SI id
select * from silver.v_reading_by_sidnl where sidnl_id = 'SI100';   -- store readings: price, stock, OSA, position
select * from silver.v_shelf_by_sidnl   where sidnl_id = 'SI100';   -- category-shelf positions (SOV, rank)
```

## Check
```bash
pip install -r requirements.txt
export SUPABASE_DB_URL='postgresql://...'      # Supabase > Connect > SESSION pooler
python -m sidnl.cli silver-report              # health, data quality, listing %
python -m sidnl.cli silver-run                 # run the pipeline now (same as cron)
python -m unittest discover -s tests -v        # 2 smoke tests
```

## Changing the database
The live database is the source of truth. The numbered files in `sql/silver/` are history and are **not** safe to re-apply.
New changes go in `sql/silver/live/<timestamp>_<name>.sql` and are applied with Supabase migrations.
