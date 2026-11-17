-- Zepto first-party (vendor portal) landing + ops tables.
-- Apply once (Supabase SQL editor or migration). Does NOT touch the `public` schema.
-- Rules: no RLS here (RLS is for dash tables only), nothing is ever deleted or overwritten,
-- every row carries brand + platform (always 'zepto' for first-party data).

create schema if not exists fp;
create schema if not exists ops;

-- Append-only version history. One row per distinct *content* of a report row:
--   * same row seen again, content identical  -> nothing new is stored (only last_seen_at is touched)
--   * same row_key, content changed           -> a NEW row is appended; the old version stays for analysis
-- The report's own columns are kept verbatim as jsonb because the exact headers of each report are
-- not known until the first real files are loaded; typed columns come later (silver / dash).
create table if not exists fp.report_rows (
  id              bigint generated always as identity primary key,
  brand           text        not null,
  platform        text        not null default 'zepto' check (platform = 'zepto'),
  report_type     text        not null,          -- key from config/reports.yaml (sales, grn, rtv, ...)
  row_key         text        not null,          -- configured key columns joined, else = row_hash
  row_hash        text        not null,          -- sha256 of the row content
  window_start    date        not null,          -- report window in which this version was first seen
  window_end      date        not null,
  source_file_id  bigint,                        -- file in which this version was first seen
  row_data        jsonb       not null,
  first_seen_at   timestamptz not null default now(),
  last_seen_at    timestamptz not null default now(),
  unique (brand, report_type, row_key, row_hash)
);
create index if not exists report_rows_lookup on fp.report_rows (brand, report_type, window_start);
create index if not exists report_rows_versions on fp.report_rows (brand, report_type, row_key, last_seen_at desc);

-- Latest version of every row (the one most recently confirmed by a report).
create or replace view fp.report_rows_current as
select distinct on (brand, report_type, row_key) *
from fp.report_rows
order by brand, report_type, row_key, last_seen_at desc, id desc;

-- Manifest of every downloaded file / failed attempt (pipeline bookkeeping lives in ops, not silver).
create table if not exists ops.fp_ingest_files (
  id              bigint generated always as identity primary key,
  brand           text        not null,
  report_key      text        not null,
  report_label    text        not null,
  window_start    date        not null,
  window_end      date        not null,
  request_id      text,
  file_name       text,
  sha256          text,
  rows_new        integer,                       -- new or changed versions appended
  rows_unchanged  integer,                       -- identical to what was already stored
  status          text        not null check (status in ('downloaded','loaded','failed')),
  error           text,
  created_at      timestamptz not null default now(),
  finished_at     timestamptz
);
create index if not exists fp_ingest_files_lookup
  on ops.fp_ingest_files (brand, report_key, window_start, window_end, status);
create index if not exists fp_ingest_files_sha on ops.fp_ingest_files (brand, report_key, sha256);

-- Companies (brand logins) that have been onboarded. Passwords are NOT stored here
-- (encrypted vault file / secret manager; see README). OTP routing is informational.
create table if not exists ops.fp_accounts (
  name            text primary key,              -- short slug, e.g. mr_munchies
  brand           text        not null,
  zepto_email     text        not null,
  otp_route       text        not null default 'manual' check (otp_route in ('manual','forward_to_mailbox','file')),
  active          boolean     not null default true,
  onboarded_at    timestamptz not null default now(),
  last_run_at     timestamptz,
  last_run_status text
);
