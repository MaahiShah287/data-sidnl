# zepto_fp - Zepto Brands first-party report automation (multi-company)

For every onboarded company (brand), twice a day: sign in to the Zepto Brands portal, request every
report, download it, and load it into Supabase. Identical data is not stored again; changed data is
appended as a new version so you can analyse how it moved. Fully automated after onboarding.

## Onboarding a company (once per company)

1. `python -m zepto_fp.run onboard` - enter the company's short name, brand, Zepto login and password
   (the password goes into the encrypted vault, not the database).
2. A browser opens; the company gives you the OTP once and you enter it. The session is saved.
3. The company forwards Zepto's OTP emails to our OTP mailbox (Outlook: Settings > Mail > Rules > forward
   to `GRAPH_MAILBOX`). Trigger a fresh OTP, then `python -m zepto_fp.run check-otp` confirms it arrived.
4. Done: the next scheduled run includes the company. When its session expires, the run re-logs in
   unattended by reading the forwarded OTP.

**Please do not collect clients' Outlook passwords.** They are not needed (forwarding covers it), Microsoft
accounts with MFA cannot be used that way anyway, and holding them makes you responsible for their mailboxes.
Even better for the Zepto login: ask the client to create a separate partner user for us in the portal's
"Users" section, so you never hold their main login. Also check Zepto's partner terms allow automated access.

## What runs every morning and evening (07:00 and 19:00 IST)

`python -m zepto_fp.run fetch --mode daily`, for every active company, one after another (OTP mails cannot mix):
1. reuse the saved session (or renew it through the forwarded OTP);
2. for each enabled report: request it for a rolling window ending yesterday (`lookback_days` per report in
   `config/reports.yaml`, longer for reports that change late: GRN, RTV...), wait until "Completed", download it;
3. skip the file entirely if a byte-identical one was already loaded; otherwise compare row by row:
   - same row, same content -> **nothing stored** (only its `last_seen_at` is touched)
   - same row, changed content -> **new version appended**, old version kept
   - new row -> appended
4. every file is logged in `ops.fp_ingest_files` (rows_new / rows_unchanged); failures are logged, sent to
   `ALERT_WEBHOOK_URL`, and one failing report never stops the rest. A lock prevents a slow morning run
   from overlapping the evening one.

Where the data lands: `fp.report_rows` (every version) and `fp.report_rows_current` (latest version per row).
History for analysis = query `fp.report_rows`. Pushing into typed **dash tables** is a second, in-database
step (pg_cron, like your silver->gold) that can only be written once the real column headers are known.

## Setup

```bash
python -m venv .venv && .venv/bin/pip install -r requirements.txt && .venv/bin/playwright install chromium
cp .env.example .env                 # fill SUPABASE_DB_URL, GRAPH_*; then: python -m zepto_fp.run vault-key  -> VAULT_KEY
# apply sql/001_fp_schema.sql once (Supabase SQL editor or migration)
python -m zepto_fp.run onboard
python -m zepto_fp.run fetch --dry-run --headed --reports grn    # first real test: download only, watch it
python -m zepto_fp.run fetch --mode backfill --since 2026-01-01  # history (31-day windows)
```

Schedule with `deploy/crontab.txt` (Linux VM) or `deploy/windows_tasks.ps1` (Windows). It needs a real browser,
so run it on a machine/VM that is always on (a fixed IP is better), not as a Supabase edge function.

## What was verified, and what was not

Tested here: code compiles; date-window splitting (unit tests); parser (csv/xlsx/zip) and stable row hashing
(same data = same hash regardless of file name/column order); encrypted vault; and the **schema + append-only
SQL on a real Postgres 16** (identical reload stores nothing, changed row is appended, revert is handled,
current-view is right). No sample data is stored anywhere in the project.

**Not tested against the live portal or Microsoft Graph** (no files could be fetched while building):
the Request-Report dialog interaction, the Download hand-off, the pre-login screens used by unattended
re-login, and the Graph OTP read. Do the first run watched (`--headed`); fixes go in `reports.py` / `auth.py`.
Also unconfirmed: whether Zepto can send the login OTP by **email** (today it goes to a phone). If it is SMS
only, forward the SMS instead (`otp_route=file` with an SMS-forwarder app).

## Still to do

- PO, Scheduled PO, Unscheduled PO, Sales Overview (in portal history, not in the Report Type dropdown;
  `enabled: false` until the PO Management / Sales Analytics sections are mapped) and the other sidebar sections.
- After the first real files load: set `key_columns` per report in the YAML (so changes are tracked as versions
  of the same row), then build silver/dash typed tables keyed by SI id, with brand + platform columns.
- `state/*.json` holds logged-in sessions: protect it like a password.
