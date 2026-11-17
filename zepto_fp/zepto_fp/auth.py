from __future__ import annotations

import re
import time
from datetime import datetime, timezone

from playwright.sync_api import BrowserContext, Page, sync_playwright

from .config import BASE_URL, Account
from .otp import OtpUnavailable, get_otp

REPORTS_URL = f"{BASE_URL}/vendor/reports"


class LoginRequired(RuntimeError):
    """Session expired and it could not be renewed unattended."""


def open_context(pw, account: Account, headless: bool) -> BrowserContext:
    browser = pw.chromium.launch(headless=headless)
    kwargs = {"accept_downloads": True, "viewport": {"width": 1440, "height": 900}}
    if account.state_file.exists():
        kwargs["storage_state"] = str(account.state_file)
    return browser.new_context(**kwargs)


def is_logged_in(page: Page) -> bool:
    page.goto(REPORTS_URL, wait_until="domcontentloaded")
    try:
        # The "Request Report" button only exists on the logged-in Reports page.
        page.get_by_role("button", name="Request Report").wait_for(timeout=20_000)
        return True
    except Exception:
        return False


def save_state(ctx: BrowserContext, account: Account) -> None:
    account.state_file.parent.mkdir(parents=True, exist_ok=True)
    ctx.storage_state(path=str(account.state_file))


def ensure_session(ctx: BrowserContext, page: Page, account: Account, otp_provider: str) -> None:
    """Reuse the saved session; renew it unattended only if an OTP provider can supply the OTP."""
    if is_logged_in(page):
        save_state(ctx, account)  # refresh cookies/expiry
        return
    if otp_provider == "manual" or not (account.email and account.password):
        raise LoginRequired(
            f"Session for '{account.name}' expired. Run: python -m zepto_fp.run login --account {account.name}"
        )
    _auto_login(page, account, otp_provider)
    if not is_logged_in(page):
        raise LoginRequired(f"Automatic login failed for '{account.name}'. Re-run the interactive `login`.")
    save_state(ctx, account)


def _auto_login(page: Page, account: Account, otp_provider: str) -> None:
    """Best-effort unattended login.

    NOTE: the pre-login screens were not inspected (the first login was done by hand), so these
    locators are generic guesses. If this step fails, adjust the locators below after running
    `login --headed` once and looking at the screens.
    """
    page.goto(BASE_URL, wait_until="domcontentloaded")
    box = page.locator('input[type="email"], input[type="tel"], input[type="text"]').first
    box.wait_for(timeout=20_000)
    box.fill(account.email)
    _click_primary(page)
    pw_box = page.locator('input[type="password"]')
    if pw_box.count():
        pw_box.first.fill(account.password)
        sent_after = datetime.now(timezone.utc)
        _click_primary(page)
    else:
        sent_after = datetime.now(timezone.utc)
    try:
        otp = get_otp(otp_provider, sent_after)
    except OtpUnavailable as e:
        raise LoginRequired(str(e)) from e
    cells = page.locator('input[maxlength="1"]')
    if cells.count() >= 4:
        for i, ch in enumerate(otp):
            cells.nth(i).fill(ch)
    else:
        page.locator('input[autocomplete="one-time-code"], input[inputmode="numeric"], input[type="tel"]').first.fill(otp)
    _click_primary(page)
    page.wait_for_url("**/vendor/**", timeout=30_000)


def _click_primary(page: Page) -> None:
    btn = page.get_by_role(
        "button", name=re.compile(r"continue|log ?in|send otp|get otp|verify|submit|next", re.I)
    )
    if btn.count():
        btn.first.click()
    else:
        page.keyboard.press("Enter")
    time.sleep(1.5)


def interactive_login(account: Account, wait_minutes: int = 10) -> None:
    """Open a visible browser; a person enters email/password/OTP; the session is saved."""
    with sync_playwright() as pw:
        ctx = open_context(pw, account, headless=False)
        page = ctx.new_page()
        page.goto(BASE_URL)
        print(f"Sign in to the Zepto portal for '{account.name}' in the browser window (waiting up to {wait_minutes} min)...")
        end = time.time() + wait_minutes * 60
        while time.time() < end:
            if "/vendor/" in page.url and page.get_by_text("Request Report").count() + page.get_by_text("Live Monitor").count():
                break
            time.sleep(2)
        else:
            raise LoginRequired("login not completed in time")
        save_state(ctx, account)
        print(f"Session saved to {account.state_file}")
        ctx.browser.close()
