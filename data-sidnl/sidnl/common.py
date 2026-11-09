import os
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent


def load_yaml(name):
    import yaml

    with open(ROOT / "config" / name, encoding="utf-8") as f:
        return yaml.safe_load(f)


def db_url():
    try:
        return os.environ["SUPABASE_DB_URL"]
    except KeyError:
        raise SystemExit("Set SUPABASE_DB_URL to the Postgres connection string "
                         "(Supabase > Connect > Session pooler). Do not put it in code.")


def connect():
    import psycopg
    conn = psycopg.connect(db_url(), prepare_threshold=None, autocommit=False, application_name="sidnl")
    with conn.cursor() as cur:
        cur.execute("set statement_timeout = 0")
    conn.commit()
    return conn
