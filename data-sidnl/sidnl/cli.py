import argparse
from .common import connect


def _with_conn(fn, *a):
    conn = connect()
    try:
        return fn(conn, *a)
    finally:
        conn.close()


def main():
    ap = argparse.ArgumentParser(prog="sidnl")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("silver-test", help="parser self-test")
    sub.add_parser("silver-report", help="pipeline health, data quality, listing %")
    r = sub.add_parser("silver-run", help="run the bronze -> silver pipeline now"); r.add_argument("--force", action="store_true")
    f = sub.add_parser("silver-refresh", help="reload one brand"); f.add_argument("--brand", default="mr munchies")
    a = ap.parse_args()

    from . import silver
    if a.cmd == "silver-test": _with_conn(silver.selftest)
    elif a.cmd == "silver-report": _with_conn(silver.report)
    elif a.cmd == "silver-run": _with_conn(silver.run, a.force)
    elif a.cmd == "silver-refresh": _with_conn(silver.refresh, a.brand)


if __name__ == "__main__":
    main()
