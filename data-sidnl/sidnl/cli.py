import argparse, threading, time
from .common import ROOT, connect


def migrate():
    conn = connect()
    for f in sorted((ROOT / "sql").glob("*.sql")):
        with conn.cursor() as cur:
            cur.execute(f.read_text(encoding="utf-8"))
        conn.commit(); print("applied", f.name)
    conn.close()


def _with_conn(fn, *a):
    conn = connect()
    try:
        return fn(conn, *a)
    finally:
        conn.close()


def daily():
    """Static / scheduled drops: load every new file in parallel, then normalise + match. Safe to re-run."""
    from . import ingest, normalize, match
    ingest.ingest_dir()
    normalize.run()
    match.run()


def live(host, port, poll):
    """Real-time: HTTP receiver + micro-batch loader + continuous normalise/match, in one process."""
    from . import stream, normalize, match

    def downstream():
        while True:
            try:
                n = normalize.run(workers=1)
                m = sum(match.run().values())
            except Exception as e:                     # never let a transient DB error kill the thread
                print("downstream error:", e); n = m = 0; time.sleep(5)
            if not (n or m):
                time.sleep(2)
    threading.Thread(target=stream.serve, args=(host, port), daemon=True).start()
    threading.Thread(target=downstream, daemon=True).start()
    stream.watch(poll=poll)


def main():
    ap = argparse.ArgumentParser(prog="sidnl")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for c in ("migrate", "seed-rules", "normalize", "match", "daily", "learn",
              "silver-apply", "silver-test", "silver-report"):
        sub.add_parser(c)
    sr = sub.add_parser("silver-refresh"); sr.add_argument("--brand", default="mr munchies")
    i = sub.add_parser("ingest"); i.add_argument("--platform", required=True); i.add_argument("--path", required=True)
    i.add_argument("--kind", choices=["static", "live"], default="static")
    s = sub.add_parser("serve"); s.add_argument("--host", default="127.0.0.1"); s.add_argument("--port", type=int, default=8080)
    w = sub.add_parser("watch"); w.add_argument("--poll", type=float, default=1.0); w.add_argument("--once", action="store_true")
    l = sub.add_parser("live"); l.add_argument("--host", default="127.0.0.1"); l.add_argument("--port", type=int, default=8080)
    l.add_argument("--poll", type=float, default=1.0)
    r = sub.add_parser("rules"); rs = r.add_subparsers(dest="rcmd", required=True)
    rs.add_parser("suggest")
    a_ = rs.add_parser("activate"); a_.add_argument("words", nargs="+")
    n_ = rs.add_parser("renormalize"); n_.add_argument("--platform")
    a = ap.parse_args()

    if a.cmd == "migrate": migrate()
    elif a.cmd == "silver-apply":
        from . import silver; _with_conn(silver.apply)
    elif a.cmd == "silver-test":
        from . import silver; _with_conn(silver.selftest)
    elif a.cmd == "silver-refresh":
        from . import silver; _with_conn(silver.refresh, a.brand)
    elif a.cmd == "silver-report":
        from . import silver; _with_conn(silver.report)
    elif a.cmd == "seed-rules":
        from . import rules; _with_conn(rules.seed)
    elif a.cmd == "learn":
        from . import rules; b, n = _with_conn(rules.learn); print(f"brand aliases learned: {b:,}; noise-word suggestions: {n:,} (review: rules suggest)")
    elif a.cmd == "rules":
        from . import rules
        if a.rcmd == "suggest":
            for word, sc in _with_conn(rules.suggest): print(f"{word:25s} {sc:.2f}")
        elif a.rcmd == "activate": _with_conn(rules.activate, a.words)
        else: print(f"flagged {_with_conn(rules.renormalize, a.platform):,} products")
    elif a.cmd == "ingest":
        from .ingest import ingest; ingest(a.platform, a.path, a.kind)
    elif a.cmd == "normalize":
        from .normalize import run; run()
    elif a.cmd == "match":
        from .match import run; run()
    elif a.cmd == "daily": daily()
    elif a.cmd == "serve":
        from .stream import serve; serve(a.host, a.port)
    elif a.cmd == "watch":
        from .stream import watch; watch(a.poll, once=a.once)
    elif a.cmd == "live": live(a.host, a.port, a.poll)


if __name__ == "__main__":
    main()
