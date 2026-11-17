"""OTP providers. The Zepto OTP currently goes to a phone, so the default is `manual`.

OTP_PROVIDER=manual   Only used for the one-off interactive `login` command (a person types the OTP
                      in the browser window). Unattended runs rely on the saved session instead.
OTP_PROVIDER=file     Reads the OTP from the file in OTP_FILE. Use this when the SMS is forwarded
                      (SMS-forwarder app, Tasker, a small webhook...) and written to that file.
OTP_PROVIDER=graph    Reads it from an Outlook / Microsoft 365 mailbox through Microsoft Graph
                      (needs an Azure app with application permission Mail.Read, scoped to one
                      mailbox). Use this once the OTP is routed to that mailbox.
"""
from __future__ import annotations

import os
import re
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests

OTP_RE = re.compile(r"(?<!\d)(\d{4,6})(?!\d)")


class OtpUnavailable(RuntimeError):
    pass


def get_otp(provider: str, sent_after: datetime, timeout_s: int = 180) -> str:
    if provider == "file":
        return _from_file(timeout_s)
    if provider == "graph":
        return _from_graph(sent_after, timeout_s)
    raise OtpUnavailable(
        f"OTP provider '{provider}' cannot supply an OTP unattended. Run `python -m zepto_fp.run login` "
        "to sign in by hand once (the session is then reused), or set OTP_PROVIDER=file|graph."
    )


def _from_file(timeout_s: int) -> str:
    path = Path(os.environ["OTP_FILE"])
    end = time.time() + timeout_s
    while time.time() < end:
        if path.exists():
            m = OTP_RE.search(path.read_text(encoding="utf-8", errors="ignore"))
            if m:
                path.unlink(missing_ok=True)  # one-time use
                return m.group(1)
        time.sleep(2)
    raise OtpUnavailable("no OTP appeared in OTP_FILE in time")


def _graph_token() -> str:
    tenant, cid, secret = (os.environ[k] for k in ("GRAPH_TENANT_ID", "GRAPH_CLIENT_ID", "GRAPH_CLIENT_SECRET"))
    r = requests.post(
        f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token",
        data={
            "client_id": cid,
            "client_secret": secret,
            "scope": "https://graph.microsoft.com/.default",
            "grant_type": "client_credentials",
        },
        timeout=30,
    )
    r.raise_for_status()
    return r.json()["access_token"]


def _from_graph(sent_after: datetime, timeout_s: int) -> str:
    mailbox = os.environ["GRAPH_MAILBOX"]
    sender_hint = os.environ.get("OTP_SENDER_HINT", "zepto").lower()
    token = _graph_token()
    since = sent_after.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    url = f"https://graph.microsoft.com/v1.0/users/{mailbox}/mailFolders/inbox/messages"
    params = {
        "$filter": f"receivedDateTime ge {since}",
        "$orderby": "receivedDateTime desc",
        "$top": "10",
        "$select": "subject,from,bodyPreview,receivedDateTime",
    }
    end = time.time() + timeout_s
    while time.time() < end:
        r = requests.get(url, headers={"Authorization": f"Bearer {token}"}, params=params, timeout=30)
        r.raise_for_status()
        for msg in r.json().get("value", []):
            sender = (msg.get("from", {}).get("emailAddress", {}).get("address") or "").lower()
            text = f"{msg.get('subject', '')} {msg.get('bodyPreview', '')}"
            if sender_hint in sender or sender_hint in text.lower():
                m = OTP_RE.search(text)
                if m:
                    return m.group(1)
        time.sleep(5)
    raise OtpUnavailable("no OTP email arrived in time")


def route_to_provider(otp_route: str) -> str:
    """Account's OTP route -> provider used for unattended re-login."""
    return {"forward_to_mailbox": "graph", "file": "file"}.get(otp_route, "manual")


def forwarded_mail_seen(hours: int = 24 * 7) -> list[str]:
    """Subjects of Zepto messages that reached the OTP mailbox recently. Used by `check-otp` to confirm
    the client's forwarding rule works (after a fresh OTP was triggered on the client's portal)."""
    mailbox = os.environ["GRAPH_MAILBOX"]
    hint = os.environ.get("OTP_SENDER_HINT", "zepto").lower()
    token = _graph_token()
    since = (datetime.now(timezone.utc) - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
    r = requests.get(
        f"https://graph.microsoft.com/v1.0/users/{mailbox}/mailFolders/inbox/messages",
        headers={"Authorization": f"Bearer {token}"},
        params={"$filter": f"receivedDateTime ge {since}", "$orderby": "receivedDateTime desc", "$top": "25",
                "$select": "subject,from,bodyPreview,receivedDateTime"},
        timeout=30,
    )
    r.raise_for_status()
    out = []
    for m in r.json().get("value", []):
        sender = (m.get("from", {}).get("emailAddress", {}).get("address") or "").lower()
        if hint in sender or hint in (m.get("subject", "") + m.get("bodyPreview", "")).lower():
            out.append(f"{m['receivedDateTime']}  {m.get('subject', '')}")
    return out
