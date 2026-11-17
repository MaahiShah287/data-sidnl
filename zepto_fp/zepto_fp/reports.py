"""Drives the portal's Reports page: request a report, wait for "Completed", download the file.

Everything here is based on the page as observed on 17 Nov 2026:
  * Reports table columns: Requested At | Request ID (UUID) | Report Type | Date Range | Status | Actions
  * "Request Report" button -> dialog with Report Type dropdown ("Select type"), From Date and
    To Date (mm/dd/yyyy) and a Submit button
  * "Download" button on completed rows; it opens a pre-signed S3 link in a new tab
"""
from __future__ import annotations

import time
from dataclasses import dataclass
from datetime import date
from pathlib import Path

import requests
from playwright.sync_api import BrowserContext, Page

from .auth import REPORTS_URL

# Finds every history row (anchored on the Request-ID cell) and tags it so it can be clicked later.
ROWS_JS = r"""
() => {
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const range = /\d{1,2} \w{3} \d{4}\s*-\s*\d{1,2} \w{3} \d{4}/;
  const rows = [];
  const seen = new Set();
  for (const el of document.querySelectorAll('div,span,td,p')) {
    if (el.children.length) continue;
    const id = el.innerText && el.innerText.trim();
    if (!id || !uuid.test(id) || seen.has(id)) continue;
    let row = el.parentElement;
    while (row && row !== document.body && !range.test(row.innerText)) row = row.parentElement;
    if (!row || row === document.body) continue;
    seen.add(id);
    row.setAttribute('data-fp-row', id);
    const lines = row.innerText.split('\n').map(s => s.trim()).filter(Boolean);
    rows.push({id, lines, hasDownload: [...row.querySelectorAll('button')].some(b => b.innerText.trim() === 'Download')});
  }
  return rows;
}
"""

STATUS_WORDS = {"completed", "failed", "processing", "pending", "in progress", "queued", "requested", "success", "error"}


@dataclass
class HistoryRow:
    id: str
    lines: list[str]
    has_download: bool

    @property
    def status(self) -> str:
        return next((l for l in self.lines if l.lower() in STATUS_WORDS), "unknown")

    @property
    def report_type(self) -> str:
        return next((l for l in self.lines if l.isupper() or "_" in l), "")


class ReportError(RuntimeError):
    pass


def history(page: Page) -> list[HistoryRow]:
    page.get_by_role("button", name="Request Report").wait_for(timeout=30_000)
    time.sleep(1.5)  # table renders after the button
    return [HistoryRow(r["id"], r["lines"], r["hasDownload"]) for r in page.evaluate(ROWS_JS)]


def open_reports(page: Page) -> None:
    page.goto(REPORTS_URL, wait_until="domcontentloaded")


def submit_request(page: Page, label: str, start: date, end: date) -> None:
    page.get_by_role("button", name="Request Report").click()
    page.get_by_text("Select type").click()
    page.get_by_text(label, exact=True).click()
    dates = page.locator('input[placeholder="mm/dd/yyyy"]')
    for i, d in enumerate((start, end)):
        dates.nth(i).click()
        page.keyboard.type(d.strftime("%m%d%Y"))
    page.get_by_role("button", name="Submit").click()


def request_and_wait(page: Page, label: str, start: date, end: date, timeout_min: int, poll_s: int) -> HistoryRow:
    """Submit one report request and block until it is Completed. Returns the history row."""
    open_reports(page)
    before = {r.id for r in history(page)}
    submit_request(page, label, start, end)

    deadline = time.time() + timeout_min * 60
    our_id: str | None = None
    while time.time() < deadline:
        time.sleep(poll_s)
        open_reports(page)
        rows = history(page)
        if our_id is None:
            new = [r for r in rows if r.id not in before]
            if new:
                our_id = new[0].id  # newest first
        if our_id:
            row = next((r for r in rows if r.id == our_id), None)
            if row and row.status.lower() in {"failed", "error"}:
                raise ReportError(f"portal marked request {our_id} as {row.status}")
            if row and row.status.lower() in {"completed", "success"} and row.has_download:
                return row
    raise ReportError(f"report '{label}' {start}..{end} not completed within {timeout_min} min (id={our_id})")


def download(page: Page, ctx: BrowserContext, request_id: str, dest_dir: Path, stem: str) -> Path:
    """Click Download on the row and save whatever arrives: a browser download, or a pre-signed S3 link
    opened in a popup (which is then fetched directly)."""
    dest_dir.mkdir(parents=True, exist_ok=True)
    got: dict = {}

    def on_download(dl):
        got["download"] = dl

    def on_page(p):
        p.on("download", on_download)
        got["popup"] = p

    page.on("download", on_download)
    ctx.on("page", on_page)
    try:
        page.locator(f'[data-fp-row="{request_id}"] button:has-text("Download")').first.click()
        end = time.time() + 90
        while time.time() < end and not got.get("download"):
            popup = got.get("popup")
            if popup and popup.url.startswith("http") and "zepto.co.in" not in popup.url.split("/")[2]:
                break
            time.sleep(0.5)
        if got.get("download"):
            dl = got["download"]
            ext = Path(dl.suggested_filename).suffix or ".csv"
            out = dest_dir / f"{stem}{ext}"
            dl.save_as(str(out))
            return out
        popup = got.get("popup")
        if not popup:
            raise ReportError("Download click produced neither a file nor a link")
        url = popup.url
        popup.close()
        ext = Path(url.split("?")[0]).suffix or ".csv"
        out = dest_dir / f"{stem}{ext}"
        with requests.get(url, stream=True, timeout=300) as r:  # pre-signed link, no auth header needed
            r.raise_for_status()
            with open(out, "wb") as f:
                for chunk in r.iter_content(1 << 20):
                    f.write(chunk)
        return out
    finally:
        page.remove_listener("download", on_download)
        ctx.remove_listener("page", on_page)
