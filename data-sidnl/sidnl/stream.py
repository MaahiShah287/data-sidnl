"""Real-time path = durable spool + micro-batch loader. No extra infrastructure.

  scraper --POST--> receiver --fsync+rename--> landing/<platform>/stream/*.ndjson   (durable BEFORE we answer 202)
  watcher: every `poll` s, coalesce all spooled files (<= max_rows) into ONE transaction via loader.load_df
           ok -> _done/     bad file -> isolated and moved to _failed/ (never blocks the queue)
           database down -> files stay put, retried automatically (nothing is lost)
Latency is poll interval + load time, i.e. seconds. To use Kafka/Redis/SQS instead, replace the receiver with a
consumer that calls loader.load_records(); everything downstream is identical."""
import hmac, json, os, shutil, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from .common import ROOT, connect
from . import loader

MAX_BODY = 32 * 1024 * 1024


def spool_dir(platform):
    return ROOT / "landing" / platform / "stream"


def write_spool(platform, records):
    d = spool_dir(platform)
    d.mkdir(parents=True, exist_ok=True)
    name = f"{time.time_ns()}-{uuid.uuid4().hex[:8]}"
    tmp = d / f"{name}.part"                       # watcher ignores .part, so it never sees half-written data
    with open(tmp, "w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(r, default=str, ensure_ascii=False) + "\n")
        f.flush(); os.fsync(f.fileno())
    os.replace(tmp, d / f"{name}.ndjson")


def parse_body(body):
    """JSON array, single JSON object, or NDJSON -> list[dict]"""
    try:
        obj = json.loads(body)
        recs = obj if isinstance(obj, list) else [obj]
    except ValueError:
        try:
            recs = [json.loads(l) for l in body.decode("utf-8").splitlines() if l.strip()]
        except ValueError as e:
            raise ValueError(f"body is not JSON / NDJSON: {e}")
    if not recs or not all(isinstance(r, dict) for r in recs):
        raise ValueError("expected a non-empty list of JSON objects")
    return recs


class _Handler(BaseHTTPRequestHandler):
    platforms, token = set(), None

    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_POST(self):
        parts = self.path.strip("/").split("/")
        if len(parts) != 2 or parts[0] != "ingest" or parts[1] not in self.platforms:
            return self._send(404, {"error": "POST /ingest/<platform>"})
        if self.token and not hmac.compare_digest(self.headers.get("X-Sidnl-Token", ""), self.token):
            return self._send(401, {"error": "bad token"})
        n = int(self.headers.get("Content-Length") or 0)
        if not 0 < n <= MAX_BODY:
            return self._send(413 if n else 400, {"error": f"body must be 1..{MAX_BODY} bytes"})
        try:
            recs = parse_body(self.rfile.read(n))
            write_spool(parts[1], recs)
        except ValueError as e:
            return self._send(400, {"error": str(e)})
        except OSError as e:
            return self._send(503, {"error": f"spool unavailable: {e}"})      # scraper should retry
        self._send(202, {"accepted": len(recs)})


def serve(host="127.0.0.1", port=8080):
    _Handler.platforms = set(loader.platform_cfg()["platforms"])
    _Handler.token = os.environ.get("SIDNL_INGEST_TOKEN")
    print(f"receiver on {host}:{port}  (token {'required' if _Handler.token else 'NOT set - bind to localhost only'})")
    ThreadingHTTPServer((host, port), _Handler).serve_forever()


def _read(path):
    with open(path, encoding="utf-8") as f:
        return [json.loads(l) for l in f if l.strip()]


def _move(f, sub, err=None):
    dest = f.parent / sub
    dest.mkdir(exist_ok=True)
    if err is not None:
        (dest / (f.name + ".err")).write_text(repr(err))
    shutil.move(str(f), str(dest / f.name))


def _load_group(conn, platform, group, recs):
    import psycopg
    try:
        n = loader.load_records(conn, platform, recs, "live", f"stream:{group[0].name}+{len(group) - 1}")
    except psycopg.OperationalError:
        raise                                                   # database trouble: keep files, retry later
    except Exception as e:
        conn.rollback()
        if len(group) == 1:
            print(f"quarantined {group[0].name}: {e}")
            _move(group[0], "_failed", e)
            return 0
        return sum(_load_group(conn, platform, [f], _read(f)) for f in group)   # isolate the poison file
    for f in group:
        _move(f, "_done")
    return n


def _drain(conn, platform, files, max_rows):
    total, group, recs = 0, [], []
    for f in files:
        try:
            r = _read(f)
        except Exception as e:
            _move(f, "_failed", e); continue
        group.append(f); recs.extend(r)
        if len(recs) >= max_rows:
            total += _load_group(conn, platform, group, recs); group, recs = [], []
    if group:
        total += _load_group(conn, platform, group, recs)
    return total


def watch(poll=1.0, max_rows=50_000, once=False):
    import psycopg
    platforms, conn = list(loader.platform_cfg()["platforms"]), None
    while True:
        did = 0
        for plat in platforms:
            d = spool_dir(plat)
            files = sorted(d.glob("*.ndjson")) if d.exists() else []
            if not files:
                continue
            try:
                conn = conn or connect()
                did += _drain(conn, plat, files, max_rows)
            except psycopg.OperationalError as e:
                print(f"database unavailable, retrying: {e}")
                try: conn and conn.close()
                except Exception: pass
                conn = None
                time.sleep(5)
        if not did:
            if once:
                return
            time.sleep(poll)
