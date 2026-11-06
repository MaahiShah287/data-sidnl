import os, pathlib, yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent

def load_yaml(name):
    with open(ROOT / "config" / name, encoding="utf-8") as f:
        return yaml.safe_load(f)

def db_url():
    try:
        return os.environ["SUPABASE_DB_URL"]
    except KeyError:
        raise SystemExit("Set SUPABASE_DB_URL to the Postgres connection string "
                         "(Supabase > Connect > Session pooler). Do not put it in code or crontab.")

def connect():
    import psycopg                                   # imported here so pure-logic code/tests need no driver
    # prepare_threshold=None keeps it safe behind pgbouncer; session-level features (advisory lock) need the
    # direct or *session* pooler endpoint, not the transaction pooler.
    conn = psycopg.connect(db_url(), prepare_threshold=None, autocommit=False, application_name="sidnl")
    with conn.cursor() as cur:
        cur.execute("set statement_timeout = 0")
        cur.execute("set synchronous_commit = off")   # faster bulk loads, safe for re-runnable ETL
    conn.commit()
    return conn
