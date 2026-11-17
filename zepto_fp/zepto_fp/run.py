"""CLI.

Onboarding a company (once):
  python -m zepto_fp.run vault-key                      # once per installation: prints a VAULT_KEY for .env
  python -m zepto_fp.run onboard                        # registers the company, signs in once (OTP typed by hand)
  python -m zepto_fp.run check-otp                      # confirms their OTP forwarding reaches our mailbox

Scheduled (morning + evening):
  python -m zepto_fp.run fetch --mode daily             # every active company, every enabled report

Other:
  python -m zepto_fp.run fetch --mode backfill --since 2026-01-01 [--account NAME]
  python -m zepto_fp.run fetch --dry-run --reports grn --account NAME      # download only
  python -m zepto_fp.run login --account NAME           # renew an expired session by hand
"""
from __future__ import annotations

import argparse
import getpass
import os
import re
import sys
import time
import traceback
from datetime import date, timedelta
from pathlib import Path

import requests
from playwright.sync_api import sync_playwright

from . import loader, reports, vault
from .auth import LoginRequired, ensure_session, interactive_login, open_context
from .config import ROOT, Account, Settings, load_settings
from .otp import forwarded_mail_seen, route_to_provider
from .parse import read_rows, sha256_file
from .windows import daily_window, date_windows

LOCK = ROOT / "data" / "run.lock"
LOCK_STALE_S = 6 * 3600


def slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", s.lower()).strip("_")


def alert(cfg: Settings, text: str) -> None:
    print(text, file=sys.stderr)
    if cfg.alert_webhook:
        try:
            requests.post(cfg.alert_webhook, json={"text": text}, timeout=15)
        except Exception:
            pass


class RunLock:
    """Stops a long morning run and the evening run from overlapping (two browsers, duplicate requests)."""

    def __enter__(self):
        LOCK.parent.mkdir(parents=True, exist_ok=True)
        if LOCK.exists() and time.time() - LOCK.stat().st_mtime < LOCK_STALE_S:
            raise SystemExit(f"another run is in progress ({LOCK}); exiting")
        LOCK.write_text(str(os.getpid()))
        return self

    def __exit__(self, *exc):
        LOCK.unlink(missing_ok=True)


# ---- accounts -------------------------------------------------------------------------------------

def get_accounts(cfg: Settings, conn, only: str | None) -> list[Account]:
    if conn is not None:
        return [Account(a["name"], a["brand"], a["email"], a["otp_route"]) for a in loader.list_accounts(conn, only)]
    # database-less dry run: one account described by environment variables
    name = os.environ.get("ZEPTO_NAME")
    if not name:
        raise SystemExit("No database configured: set SUPABASE_DB_URL, or ZEPTO_NAME/ZEPTO_BRAND/ZEPTO_EMAIL for a dry run")
    return [Account(name, os.environ.get("ZEPTO_BRAND", name), os.environ.get("ZEPTO_EMAIL", ""))]


def _need_db(cfg: Settings) -> str:
    if not cfg.db_url:
        raise SystemExit("SUPABASE_DB_URL is not set")
    return cfg.db_url


# ---- commands -------------------------------------------------------------------------------------

def cmd_vault_key(cfg, args) -> int:
    print("Add this line to .env (and keep it secret; losing it means re-entering client passwords):")
    print(f"VAULT_KEY={vault.generate_key()}")
    return 0


def cmd_onboard(cfg: Settings, args) -> int:
    conn = loader.connect(_need_db(cfg))
    name = slug(args.name or input("Short name for the company (e.g. mr_munchies): "))
    brand = args.brand or input("Brand name as it should appear in reports: ").strip()
    email = args.email or input("Zepto portal login (email): ").strip()
    password = getpass.getpass("Zepto portal password (stored encrypted, never shown again): ")
    route = args.otp_route
    vault.set_password(name, password)
    loader.register_account(conn, name=name, brand=brand, email=email, otp_route=route)
    acc = Account(name, brand, email, route)
    print("\nStep 1/2 - one-time sign-in. A browser opens: enter the login, password and the OTP the company gives you.")
    interactive_login(acc)
    print("\nStep 2/2 - ask the company to forward the Zepto OTP to our mailbox (Outlook: Settings > Mail > Rules >")
    print(f"  'Forward to' {os.environ.get('GRAPH_MAILBOX', '<our OTP mailbox>')} for messages from/containing 'zepto').")
    print("Then run:  python -m zepto_fp.run check-otp   (after triggering a fresh OTP) to confirm it arrives.")
    print(f"\nOnboarded '{name}'. It will be picked up by the next scheduled `fetch`.")
    return 0


def cmd_check_otp(cfg: Settings, args) -> int:
    seen = forwarded_mail_seen(args.hours)
    if seen:
        print(f"OK - {len(seen)} Zepto message(s) reached the OTP mailbox in the last {args.hours}h:")
        print("\n".join("  " + s for s in seen[:10]))
        return 0
    print(f"No Zepto message reached the OTP mailbox in the last {args.hours}h. Check the client's forwarding rule.")
    return 1


def cmd_login(cfg: Settings, args) -> int:
    conn = loader.connect(_need_db(cfg)) if cfg.db_url else None
    for acc in get_accounts(cfg, conn, args.account):
        interactive_login(acc)
    return 0


def windows_for(rep, args, today: date):
    if args.mode == "backfill":
        if not args.since:
            raise SystemExit("--since is required for backfill")
        until = date.fromisoformat(args.until) if args.until else today - timedelta(days=1)
        return date_windows(date.fromisoformat(args.since), until, rep.max_days)
    return [daily_window(today, rep.lookback_days)]


def cmd_fetch(cfg: Settings, args) -> int:
    with RunLock():
        return _fetch(cfg, args)


def _fetch(cfg: Settings, args) -> int:
    today = date.today()
    wanted = set(args.reports.split(",")) if args.reports else None
    reps = [r for r in cfg.reports if r.enabled and (not wanted or r.key in wanted)]
    conn = None if args.dry_run and not cfg.db_url else loader.connect(_need_db(cfg))
    use_db = conn is not None and not args.dry_run
    failures: list[str] = []
    totals = {"new": 0, "unchanged": 0, "files": 0}

    with sync_playwright() as pw:
        for acc in get_accounts(cfg, conn, args.account):  # accounts run one after another (OTP mails can't mix)
            acc_fail_before = len(failures)
            ctx = open_context(pw, acc, headless=cfg.headless and not args.headed)
            page = ctx.new_page()
            try:
                ensure_session(ctx, page, acc, route_to_provider(acc.otp_route))
            except LoginRequired as e:
                failures.append(f"[{acc.name}] {e}")
                ctx.browser.close()
                if use_db:
                    loader.touch_account(conn, acc.name, "login required")
                continue

            for rep in reps:
                for start, end in windows_for(rep, args, today):
                    tag = f"[{acc.name}] {rep.key} {start}..{end}"
                    try:
                        if use_db and args.mode == "backfill" and loader.already_loaded(conn, acc.brand, rep.key, start, end):
                            print(f"{tag}: already loaded, skipped")
                            continue
                        row = reports.request_and_wait(page, rep.label, start, end, cfg.request_timeout_min, cfg.poll_seconds)
                        stem = f"{start}_{end}_{row.id[:8]}"
                        path = reports.download(page, ctx, row.id, cfg.raw_dir / slug(acc.brand) / rep.key, stem)
                        if not use_db:
                            print(f"{tag}: downloaded {path} (dry run)")
                            continue
                        res = _load(conn, acc, rep, start, end, row.id, path)
                        if res is None:
                            print(f"{tag}: file identical to one already loaded, nothing to add")
                            continue
                        new, unchanged = res
                        totals["new"] += new
                        totals["unchanged"] += unchanged
                        totals["files"] += 1
                        print(f"{tag}: {new} new/changed, {unchanged} unchanged")
                    except LoginRequired as e:
                        failures.append(f"{tag}: {e}")
                        break
                    except Exception as e:  # keep going; one bad report must not stop the others
                        traceback.print_exc()
                        failures.append(f"{tag}: {type(e).__name__}: {e}")
                        if use_db:
                            conn.rollback()
                            loader.record_failure(conn, brand=acc.brand, report_key=rep.key, label=rep.label,
                                                  start=start, end=end, error=f"{type(e).__name__}: {e}")
            ctx.browser.close()
            if use_db:
                status = "ok" if len(failures) == acc_fail_before else f"{len(failures) - acc_fail_before} failure(s)"
                loader.touch_account(conn, acc.name, status)

    if conn:
        conn.close()
    summary = f"{totals['files']} file(s): {totals['new']} new/changed rows appended, {totals['unchanged']} unchanged."
    if failures:
        alert(cfg, f"Zepto FP run finished with {len(failures)} failure(s). {summary}\n" + "\n".join(failures))
        return 1
    print(f"Run complete. {summary}")
    return 0


def _load(conn, acc: Account, rep, start, end, request_id, path: Path):
    """Returns (new, unchanged) or None when a byte-identical file was already loaded."""
    sha = sha256_file(path)
    if loader.same_file_loaded(conn, acc.brand, rep.key, sha):
        return None
    rows = read_rows(path)
    file_id = loader.start_file(conn, brand=acc.brand, report_key=rep.key, label=rep.label, start=start, end=end,
                                request_id=request_id, file_name=path.name, sha256=sha)
    try:
        new, unchanged = loader.upsert_rows(conn, file_id=file_id, brand=acc.brand, report_key=rep.key,
                                            start=start, end=end, rows=rows, key_columns=rep.key_columns)
        loader.finish_file(conn, file_id, new, unchanged)  # commits rows + manifest together
        return new, unchanged
    except Exception as e:
        conn.rollback()
        loader.finish_file(conn, file_id, 0, 0, status="failed", error=f"{type(e).__name__}: {e}"[:2000])
        raise


def main() -> int:
    p = argparse.ArgumentParser(prog="zepto_fp")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("vault-key")
    op = sub.add_parser("onboard")
    op.add_argument("--name")
    op.add_argument("--brand")
    op.add_argument("--email")
    op.add_argument("--otp-route", choices=["manual", "forward_to_mailbox", "file"], default="forward_to_mailbox")
    cp = sub.add_parser("check-otp")
    cp.add_argument("--hours", type=int, default=24 * 7)
    lp = sub.add_parser("login")
    lp.add_argument("--account")
    fp = sub.add_parser("fetch")
    fp.add_argument("--mode", choices=["daily", "backfill"], default="daily")
    fp.add_argument("--since")
    fp.add_argument("--until")
    fp.add_argument("--account")
    fp.add_argument("--reports", help="comma-separated report keys from config/reports.yaml")
    fp.add_argument("--dry-run", action="store_true")
    fp.add_argument("--headed", action="store_true")
    args = p.parse_args()
    cfg = load_settings()
    return {"vault-key": cmd_vault_key, "onboard": cmd_onboard, "check-otp": cmd_check_otp,
            "login": cmd_login, "fetch": cmd_fetch}[args.cmd](cfg, args)


if __name__ == "__main__":
    sys.exit(main())
