-- =============================================================================
-- File:    03_roles.sql
-- Purpose: Read-only role for the SIDNL chatbot.
-- =============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sidnl_chatbot_ro') THEN
        CREATE ROLE sidnl_chatbot_ro NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
        COMMENT ON ROLE sidnl_chatbot_ro IS 'Read-only chatbot role — views only, no base tables.';
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
GRANT USAGE ON SCHEMA silver TO sidnl_chatbot_ro;
REVOKE ALL ON SCHEMA public FROM sidnl_chatbot_ro;

GRANT SELECT ON silver.v_all_platforms         TO sidnl_chatbot_ro;
GRANT SELECT ON silver.v_latest_observation    TO sidnl_chatbot_ro;
GRANT SELECT ON silver.v_latest_shelf_position TO sidnl_chatbot_ro;

REVOKE ALL ON silver.blinkit   FROM sidnl_chatbot_ro;
REVOKE ALL ON silver.zepto     FROM sidnl_chatbot_ro;
REVOKE ALL ON silver.instamart FROM sidnl_chatbot_ro;
REVOKE ALL ON silver.jiomart   FROM sidnl_chatbot_ro;

ALTER ROLE sidnl_chatbot_ro SET statement_timeout = '10s';
ALTER ROLE sidnl_chatbot_ro SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE sidnl_chatbot_ro SET default_transaction_read_only = on;
