-- =============================================================================
-- File:    03_roles.sql
-- Purpose: Read-only role for the SIDNL chatbot — Silver + Gold (dash).
--
-- Run as the database owner (postgres / Supabase SQL editor), once, then
-- re-run after adding new Gold tables (or rely on the DEFAULT PRIVILEGES below).
--
-- Layering:
--   * This file grants the DATABASE read access to the whole silver and dash
--     schemas. That is intentionally broad and read-only.
--   * The CHATBOT's own guardrail is src/db/safe_sql.py: the LLM may only
--     reference a curated allowlist of relations. DB grants do not widen that.
-- =============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sidnl_chatbot_ro') THEN
        CREATE ROLE sidnl_chatbot_ro NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
        COMMENT ON ROLE sidnl_chatbot_ro IS 'Read-only chatbot role — Silver + Gold (dash), no writes.';
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sidnl_chatbot_app') THEN
        CREATE ROLE sidnl_chatbot_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
            PASSWORD 'CHANGE_ME_BEFORE_DEPLOY';
    END IF;
END $$;

GRANT sidnl_chatbot_ro TO sidnl_chatbot_app;

-- ---------------------------------------------------------------------------
-- Schema usage
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA silver TO sidnl_chatbot_ro;
GRANT USAGE ON SCHEMA dash   TO sidnl_chatbot_ro;

-- The chatbot never reads these: auth/app/ops/storage hold users, jobs, logs.
REVOKE ALL ON SCHEMA public     FROM sidnl_chatbot_ro;
REVOKE ALL ON SCHEMA app        FROM sidnl_chatbot_ro;
REVOKE ALL ON SCHEMA ops        FROM sidnl_chatbot_ro;
REVOKE ALL ON SCHEMA auth       FROM sidnl_chatbot_ro;
REVOKE ALL ON SCHEMA storage    FROM sidnl_chatbot_ro;
REVOKE ALL ON SCHEMA extensions FROM sidnl_chatbot_ro;
REVOKE ALL ON SCHEMA cron       FROM sidnl_chatbot_ro;
REVOKE ALL ON SCHEMA net        FROM sidnl_chatbot_ro;

-- ---------------------------------------------------------------------------
-- SELECT on Silver (existing views + the rest of the layer)
-- ---------------------------------------------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA silver TO sidnl_chatbot_ro;

-- Keep the explicit grants so a partially-applied script still works.
GRANT SELECT ON silver.v_all_platforms         TO sidnl_chatbot_ro;
GRANT SELECT ON silver.v_latest_observation    TO sidnl_chatbot_ro;
GRANT SELECT ON silver.v_latest_shelf_position TO sidnl_chatbot_ro;

-- Base scraped tables stay unreadable from the chatbot's allowlist; revoking
-- here is belt-and-braces if a previous version granted them.
REVOKE ALL ON silver.blinkit   FROM sidnl_chatbot_ro;
REVOKE ALL ON silver.zepto     FROM sidnl_chatbot_ro;
REVOKE ALL ON silver.instamart FROM sidnl_chatbot_ro;
REVOKE ALL ON silver.jiomart   FROM sidnl_chatbot_ro;

-- ---------------------------------------------------------------------------
-- SELECT on Gold (dash) — the whole layer
-- ---------------------------------------------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA dash TO sidnl_chatbot_ro;

-- Views created by the Gold refresh (owned by postgres) must also be readable
-- after future refreshes, not just the ones that exist today.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA silver
    GRANT SELECT ON TABLES TO sidnl_chatbot_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA dash
    GRANT SELECT ON TABLES TO sidnl_chatbot_ro;

-- ---------------------------------------------------------------------------
-- Runtime guards (belt-and-braces; the app also sets these per connection)
-- ---------------------------------------------------------------------------
ALTER ROLE sidnl_chatbot_ro  SET statement_timeout = '10s';
ALTER ROLE sidnl_chatbot_ro  SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE sidnl_chatbot_ro  SET default_transaction_read_only = on;

ALTER ROLE sidnl_chatbot_app SET statement_timeout = '10s';
ALTER ROLE sidnl_chatbot_app SET default_transaction_read_only = on;
