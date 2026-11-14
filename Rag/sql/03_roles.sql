-- =============================================================================
-- File:    03_roles.sql
-- Purpose: Read-only role for the SIDNL chatbot — Silver + Gold (dash).
--
-- Run as the database owner (postgres / Supabase SQL editor), once, then
-- re-run after adding new Gold tables (or rely on the DEFAULT PRIVILEGES below).
--
-- Role model: `sidnl_chatbot_app` is the single read-only LOGIN role the app
-- connects as (verify with `select current_user`). It holds the privileges
-- directly. Do not route grants through a separate NOLOGIN role: an earlier
-- version used `sidnl_chatbot_ro NOINHERIT`, which both did not exist in this
-- database and would not have passed its privileges to the login role anyway.
--
-- Layering:
--   * This file grants the DATABASE read access to the whole silver and dash
--     schemas. That is intentionally broad and read-only.
--   * The CHATBOT's own guardrail is src/db/safe_sql.py: the LLM may only
--     reference a curated allowlist of relations. DB grants do not widen that.
-- =============================================================================

-- Create the login role only if it is missing. Set a real password out-of-band
-- (Supabase dashboard or ALTER ROLE ... PASSWORD) — never commit a password.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sidnl_chatbot_app') THEN
        CREATE ROLE sidnl_chatbot_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
        COMMENT ON ROLE sidnl_chatbot_app IS
            'Read-only chatbot login — Silver + Gold (dash), no writes.';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Schema usage
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA silver TO sidnl_chatbot_app;
GRANT USAGE ON SCHEMA dash   TO sidnl_chatbot_app;

-- The chatbot never reads these: auth/app/ops/storage hold users, jobs, logs.
REVOKE ALL ON SCHEMA public     FROM sidnl_chatbot_app;
REVOKE ALL ON SCHEMA app        FROM sidnl_chatbot_app;
REVOKE ALL ON SCHEMA ops        FROM sidnl_chatbot_app;
REVOKE ALL ON SCHEMA auth       FROM sidnl_chatbot_app;
REVOKE ALL ON SCHEMA storage    FROM sidnl_chatbot_app;
REVOKE ALL ON SCHEMA extensions FROM sidnl_chatbot_app;
REVOKE ALL ON SCHEMA cron       FROM sidnl_chatbot_app;
REVOKE ALL ON SCHEMA net        FROM sidnl_chatbot_app;

-- ---------------------------------------------------------------------------
-- SELECT on Silver (existing views + the rest of the layer)
-- ---------------------------------------------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA silver TO sidnl_chatbot_app;

-- Keep the explicit grants so a partially-applied script still works.
GRANT SELECT ON silver.v_all_platforms         TO sidnl_chatbot_app;
GRANT SELECT ON silver.v_latest_observation    TO sidnl_chatbot_app;
GRANT SELECT ON silver.v_latest_shelf_position TO sidnl_chatbot_app;

-- Base scraped tables stay unreadable from the chatbot's allowlist; revoking
-- here is belt-and-braces if a previous version granted them.
REVOKE ALL ON silver.blinkit   FROM sidnl_chatbot_app;
REVOKE ALL ON silver.zepto     FROM sidnl_chatbot_app;
REVOKE ALL ON silver.instamart FROM sidnl_chatbot_app;
REVOKE ALL ON silver.jiomart   FROM sidnl_chatbot_app;

-- ---------------------------------------------------------------------------
-- SELECT on Gold (dash) — the whole layer
-- ---------------------------------------------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA dash TO sidnl_chatbot_app;

-- Views created by the Gold refresh (owned by postgres) must also be readable
-- after future refreshes, not just the ones that exist today.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA silver
    GRANT SELECT ON TABLES TO sidnl_chatbot_app;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA dash
    GRANT SELECT ON TABLES TO sidnl_chatbot_app;

-- ---------------------------------------------------------------------------
-- Runtime guards (belt-and-braces; the app also sets these per connection)
-- ---------------------------------------------------------------------------
ALTER ROLE sidnl_chatbot_app SET statement_timeout = '10s';
ALTER ROLE sidnl_chatbot_app SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE sidnl_chatbot_app SET default_transaction_read_only = on;
