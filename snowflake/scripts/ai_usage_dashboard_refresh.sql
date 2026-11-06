/*==============================================================================
  ai_usage_dashboard_refresh.sql: backend for the self-service AI usage dashboard
  ------------------------------------------------------------------------------
  SCOPE: dashboard only. ENFORCE_CORTEX_AI_LIMITS, RESET_ALL_AI_ACCESS and their
  tasks are NOT changed. This adds three tables and one hourly procedure that
  the dashboard reads, so the dashboard no longer queries ACCOUNT_USAGE live.

  HOW THE NUMBERS LINE UP WITH ENFORCEMENT
    The monthly "used" figure follows ENFORCE_CORTEX_AI_LIMITS exactly: the same
    sources (AI Functions, Cortex Analyst, Cortex Agents, Snowflake Intelligence,
    CoCo CLI, REST API), the same REST API rate table with cache rates, and the
    same session-timezone month boundary. CoCo in Snowsight and Desktop is also
    loaded, but flagged COUNTS_TOWARD_BUDGET = FALSE, because enforcement doesn't
    count it. Users still see it, labeled as not counted.

  OBJECTS
    All three are TRANSIENT with DATA_RETENTION_TIME_IN_DAYS = 0 (no Time
    Travel, no Fail-safe), and hold only what the dashboard shows:
    AI_DASH_USAGE_DAILY   per user / day / source / detail; previous + current
                          month only (older rows deleted every run)
    AI_DASH_USER_STATUS   one row per user, on the tier role that governs their
                          access: limit, used, ACTIVE / OVER_LIMIT / REVOKED; current snapshot only (overwritten every run)
    AI_DASH_COCO_24H      per user + CoCo interface: last-24h credits vs daily
                          limit; current snapshot only (overwritten every run)
    REFRESH_AI_USAGE_DASHBOARD()       hourly procedure
    REFRESH_AI_USAGE_DASHBOARD_TASK    hourly task

  CHECK BEFORE RUNNING (not run against a live account; test in dev first)
    - LOGGED_AT (3 places, marked CHECK): AI_ENFORCEMENT_LOG's timestamp column.
    - default_daily (10): should match the account-level CoCo daily limits.
    - The task must run with the same session timezone as the enforcement task,
      so "this month" starts at the same moment in both.
    - REST API model rates are copied from hourly_revoke.sql. If that table
      changes, change this one too.
==============================================================================*/

USE SCHEMA AI_COST_MGMT.PUBLIC;

-- -----------------------------------------------------------------------------
-- Tables
-- -----------------------------------------------------------------------------
CREATE TRANSIENT TABLE IF NOT EXISTS AI_COST_MGMT.PUBLIC.AI_DASH_USAGE_DAILY (
    USAGE_DATE            DATE,
    USER_NAME             VARCHAR,
    SOURCE                VARCHAR,       -- AI Functions, Cortex Analyst, Cortex Agents, Snowflake Intelligence,
                                         -- CoCo CLI, CoCo Desktop, CoCo Snowsight, REST API
    DETAIL                VARCHAR,       -- function and model (AI Functions), model (REST API), else NULL
    CREDITS               NUMBER(38,6),
    COUNTS_TOWARD_BUDGET  BOOLEAN,
    REFRESHED_AT          TIMESTAMP_LTZ
);

CREATE TRANSIENT TABLE IF NOT EXISTS AI_COST_MGMT.PUBLIC.AI_DASH_USER_STATUS (
    USER_NAME             VARCHAR,
    TIER_ROLE             VARCHAR,
    MONTHLY_CREDIT_LIMIT  NUMBER(38,6),
    CREDITS_USED          NUMBER(38,6),
    STATUS                VARCHAR,       -- ACTIVE / OVER_LIMIT / REVOKED
    REVOKED_AT            TIMESTAMP_LTZ,
    MONTH_START           TIMESTAMP_LTZ,
    REFRESHED_AT          TIMESTAMP_LTZ
);

CREATE TRANSIENT TABLE IF NOT EXISTS AI_COST_MGMT.PUBLIC.AI_DASH_COCO_24H (
    USER_NAME             VARCHAR,
    INTERFACE             VARCHAR,
    CREDITS_24H           NUMBER(38,6),
    DAILY_LIMIT           NUMBER,        -- -1 = unlimited
    EXCEPTION_EXPIRES_AT  TIMESTAMP_LTZ,
    REFRESHED_AT          TIMESTAMP_LTZ
);

-- Transient + no Time Travel: these tables are rebuilt hourly from
-- ACCOUNT_USAGE, so there's nothing to recover and no reason to pay to keep
-- old versions of rows (transient tables also have no Fail-safe).
ALTER TABLE AI_COST_MGMT.PUBLIC.AI_DASH_USAGE_DAILY SET DATA_RETENTION_TIME_IN_DAYS = 0;
ALTER TABLE AI_COST_MGMT.PUBLIC.AI_DASH_USER_STATUS SET DATA_RETENTION_TIME_IN_DAYS = 0;
ALTER TABLE AI_COST_MGMT.PUBLIC.AI_DASH_COCO_24H    SET DATA_RETENTION_TIME_IN_DAYS = 0;

-- -----------------------------------------------------------------------------
-- Procedure
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE AI_COST_MGMT.PUBLIC.REFRESH_AI_USAGE_DASHBOARD()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    month_start    TIMESTAMP_LTZ;
    window_start   TIMESTAMP_LTZ;
    run_ts         TIMESTAMP_LTZ;
    default_daily  NUMBER  DEFAULT 10;     -- account-level CoCo daily limit
    coco_msg       VARCHAR DEFAULT 'ok';
BEGIN
    -- Same month boundary as enforcement. The window also covers the last 30
    -- days so the Activity tab can look back across a month boundary.
    SELECT DATE_TRUNC('month', CURRENT_TIMESTAMP()),
           -- never earlier than the start of last month (e.g. on March 1,
           -- 30 days back would reach into January)
           GREATEST(DATEADD('month', -1, DATE_TRUNC('month', CURRENT_TIMESTAMP())),
                    LEAST(DATE_TRUNC('month', CURRENT_TIMESTAMP()),
                          DATEADD('day', -30, DATE_TRUNC('day', CURRENT_TIMESTAMP())))),
           CURRENT_TIMESTAMP()
      INTO :month_start, :window_start, :run_ts;

    -------------------------------------------------------------------------
    -- 1. Usage per user / day / source / detail
    -------------------------------------------------------------------------
    BEGIN TRANSACTION;

    -- Rebuild the recent window, and drop anything older than the start of
    -- last month, so the table only ever holds the previous and current month.
    -- (Last month's rows older than 31 days stay as last computed: ACCOUNT_USAGE
    -- rarely changes that far back, and re-scanning them hourly would cost more.)
    DELETE FROM AI_COST_MGMT.PUBLIC.AI_DASH_USAGE_DAILY
     WHERE USAGE_DATE >= :window_start::DATE
        OR USAGE_DATE <  DATEADD('month', -1, :month_start)::DATE;

    INSERT INTO AI_COST_MGMT.PUBLIC.AI_DASH_USAGE_DAILY
        (USAGE_DATE, USER_NAME, SOURCE, DETAIL, CREDITS, COUNTS_TOWARD_BUDGET, REFRESHED_AT)
    WITH
    -- Copied from ENFORCE_CORTEX_AI_LIMITS so REST API estimates match enforcement
    model_rates AS (
        SELECT column1 AS model_name,
               column2 AS input_rate,
               column3 AS output_rate,
               column4 AS cache_write_rate,
               column5 AS cache_read_rate
        FROM VALUES
            ('claude-4-sonnet',         1.50,  7.50,  1.875, 0.15),
            ('claude-sonnet-4-5',       1.50,  7.50,  1.875, 0.15),
            ('claude-sonnet-4-6',       1.50,  7.50,  1.875, 0.15),
            ('claude-sonnet-5',         1.00,  5.00,  1.25,  0.10),
            ('claude-haiku-4-5',        0.50,  2.50,  0.625, 0.05),
            ('claude-opus-4-5',         2.50, 12.50,  3.125, 0.25),
            ('claude-opus-4-6',         2.50, 12.50,  3.125, 0.25),
            ('claude-opus-4-7',         2.50, 12.50,  3.125, 0.25),
            ('claude-opus-4-8',         2.50, 12.50,  3.125, 0.25),
            ('openai-gpt-4.1',          1.00,  4.00,  NULL,  0.25),
            ('openai-gpt-5',            0.625, 5.00,  NULL,  0.065),
            ('openai-gpt-5-mini',       0.125, 1.00,  NULL,  0.015),
            ('openai-gpt-5-nano',       0.03,  0.22,  NULL,  0.005),
            ('openai-gpt-5.1',          0.625, 5.00,  NULL,  0.065),
            ('openai-gpt-5.2',          0.875, 7.00,  NULL,  0.09),
            ('openai-gpt-5.4',          1.25,  7.50,  NULL,  0.125),
            ('openai-gpt-5.4-mini',     0.375, 2.25,  NULL,  0.038),
            ('openai-gpt-5.4-nano',     0.10,  0.625, NULL,  0.01),
            ('grok-4.20',               0.625, 1.25,  NULL,  0.10),
            ('grok-4.3',                0.625, 1.25,  NULL,  0.10),
            ('llama3.1-405b',           1.20,  1.20,  NULL,  NULL),
            ('llama3.1-70b',            0.36,  0.36,  NULL,  NULL),
            ('llama3.1-8b',             0.11,  0.11,  NULL,  NULL),
            ('llama3.3-70b',            0.36,  0.36,  NULL,  NULL),
            ('llama4-maverick',         0.144, 0.582, NULL,  NULL),
            ('llama4-scout',            0.102, 0.396, NULL,  NULL),
            ('mistral-large2',          1.00,  3.00,  NULL,  NULL),
            ('mistral-7b',              0.075, 0.10,  NULL,  NULL),
            ('mixtral-8x7b',            0.27,  0.42,  NULL,  NULL),
            ('deepseek-r1',             0.675, 2.70,  NULL,  NULL),
            ('snowflake-llama-3.3-70b', 0.36,  0.36,  NULL,  NULL)
    ),
    -- Every branch casts its time to TIMESTAMP_LTZ: some views use LTZ, the CoCo
    -- views use TIMESTAMP_TZ, and UNION ALL needs one type per column.
    src AS (
        -- Counted toward the monthly budget (same sources as enforcement) --------
        SELECT u.NAME AS USER_NAME, TO_TIMESTAMP_LTZ(h.START_TIME) AS TS, 'AI Functions' AS SOURCE,
               h.FUNCTION_NAME || ' · ' || h.MODEL_NAME AS DETAIL, h.CREDITS AS CREDITS, TRUE AS COUNTS
          FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY h
          JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON h.USER_ID = u.USER_ID
         WHERE h.START_TIME >= :window_start

        UNION ALL
        SELECT USERNAME, TO_TIMESTAMP_LTZ(START_TIME), 'Cortex Analyst', NULL, CREDITS, TRUE
          FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_ANALYST_USAGE_HISTORY
         WHERE START_TIME >= :window_start

        UNION ALL
        SELECT USER_NAME, TO_TIMESTAMP_LTZ(START_TIME), 'Cortex Agents', NULL, TOKEN_CREDITS, TRUE
          FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
         WHERE START_TIME >= :window_start

        UNION ALL
        SELECT USER_NAME, TO_TIMESTAMP_LTZ(START_TIME), 'Snowflake Intelligence', NULL, TOKEN_CREDITS, TRUE
          FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY
         WHERE START_TIME >= :window_start

        UNION ALL
        SELECT u.NAME, TO_TIMESTAMP_LTZ(h.USAGE_TIME), 'CoCo CLI', NULL, h.TOKEN_CREDITS, TRUE
          FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_CLI_USAGE_HISTORY h
          JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON h.USER_ID = u.USER_ID
         WHERE h.USAGE_TIME >= :window_start

        UNION ALL
        SELECT u.NAME, TO_TIMESTAMP_LTZ(r.START_TIME), 'REST API', r.MODEL_NAME,
               ROUND(
                   (COALESCE(r.TOKENS_GRANULAR:input::INT,             0) / 1000000.0) * COALESCE(mr.input_rate,       0)
                 + (COALESCE(r.TOKENS_GRANULAR:cache_write_input::INT, 0) / 1000000.0) * COALESCE(mr.cache_write_rate, 0)
                 + (COALESCE(r.TOKENS_GRANULAR:cache_read_input::INT,  0) / 1000000.0) * COALESCE(mr.cache_read_rate,  0)
                 + (COALESCE(r.TOKENS_GRANULAR:output::INT,            0) / 1000000.0) * COALESCE(mr.output_rate,      0)
               , 6),
               TRUE
          FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_REST_API_USAGE_HISTORY r
          LEFT JOIN model_rates mr ON LOWER(r.MODEL_NAME) = LOWER(mr.model_name)
          JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON r.USER_ID = u.USER_ID
         WHERE r.START_TIME >= :window_start

        -- Shown but NOT counted toward the monthly budget (enforcement skips them)
        UNION ALL
        SELECT u.NAME, TO_TIMESTAMP_LTZ(h.USAGE_TIME), 'CoCo Desktop', NULL, h.TOKEN_CREDITS, FALSE
          FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_DESKTOP_USAGE_HISTORY h
          JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON h.USER_ID = u.USER_ID
         WHERE h.USAGE_TIME >= :window_start

        UNION ALL
        SELECT u.NAME, TO_TIMESTAMP_LTZ(h.USAGE_TIME), 'CoCo Snowsight', NULL, h.TOKEN_CREDITS, FALSE
          FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY h
          JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON h.USER_ID = u.USER_ID
         WHERE h.USAGE_TIME >= :window_start
    )
    SELECT TS::DATE, USER_NAME, SOURCE, DETAIL, SUM(CREDITS), COUNTS, :run_ts
      FROM src
     GROUP BY 1, 2, 3, 4, 6;

    COMMIT;

    -------------------------------------------------------------------------
    -- 2. Per-user budget status (read-only view of what enforcement did)
    -------------------------------------------------------------------------
    INSERT OVERWRITE INTO AI_COST_MGMT.PUBLIC.AI_DASH_USER_STATUS
    WITH
    -- Revoked this month and not reset since. Enforcement can log the same
    -- revoke more than once; the latest row wins.
    revoked AS (
        SELECT USER_NAME, TIER_ROLE, LOGGED_AT AS REVOKED_AT                       -- CHECK: LOGGED_AT
          FROM AI_COST_MGMT.PUBLIC.AI_ENFORCEMENT_LOG
         WHERE LOGGED_AT >= :month_start                                            -- CHECK: LOGGED_AT
           AND ACTION IN ('REVOKED', 'RESET')
        QUALIFY ROW_NUMBER() OVER (PARTITION BY USER_NAME, TIER_ROLE ORDER BY LOGGED_AT DESC) = 1   -- CHECK: LOGGED_AT
            AND ACTION = 'REVOKED'
    ),
    -- Same membership rule as enforcement, plus revoked users (they no longer hold the role)
    members AS (
        SELECT GRANTEE_NAME AS USER_NAME, ROLE AS TIER_ROLE
          FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
         WHERE ROLE IN ('AI_EXPLORER', 'AI_DATA_SCIENCE')
           AND DELETED_ON IS NULL
        UNION
        SELECT USER_NAME, TIER_ROLE FROM revoked
    ),
    spend AS (
        SELECT USER_NAME, SUM(CREDITS) AS CREDITS
          FROM AI_COST_MGMT.PUBLIC.AI_DASH_USAGE_DAILY
         WHERE USAGE_DATE >= :month_start::DATE
           AND COUNTS_TOWARD_BUDGET
         GROUP BY USER_NAME
    )
    SELECT m.USER_NAME,
           m.TIER_ROLE,
           rb.MONTHLY_CREDIT_LIMIT,
           COALESCE(s.CREDITS, 0),
           CASE
               WHEN r.USER_NAME IS NOT NULL                          THEN 'REVOKED'
               WHEN COALESCE(s.CREDITS, 0) > rb.MONTHLY_CREDIT_LIMIT THEN 'OVER_LIMIT'
               ELSE 'ACTIVE'
           END,
           r.REVOKED_AT,
           :month_start,
           :run_ts
      FROM members m
      JOIN AI_COST_MGMT.PUBLIC.AI_ROLE_BUDGETS rb ON m.TIER_ROLE = rb.ROLE_NAME
      LEFT JOIN spend   s ON m.USER_NAME = s.USER_NAME
      LEFT JOIN revoked r ON m.USER_NAME = r.USER_NAME AND m.TIER_ROLE = r.TIER_ROLE
    -- One row per user. A user with several tier roles is shown on the role
    -- that actually governs their access: a role they still hold (not revoked
    -- this month) first, then the highest limit. If every role was revoked,
    -- the highest one is shown as REVOKED.
    QUALIFY ROW_NUMBER() OVER (
                PARTITION BY m.USER_NAME
                ORDER BY IFF(r.USER_NAME IS NULL, 0, 1),     -- still held first
                         rb.MONTHLY_CREDIT_LIMIT DESC,       -- then highest limit
                         m.TIER_ROLE                         -- tie-break, stable
            ) = 1;

    -------------------------------------------------------------------------
    -- 3. CoCo last 24 hours per interface vs the account-level daily limit.
    --    No exceptions yet: every user gets default_daily. EXCEPTION_EXPIRES_AT
    --    stays NULL so the table shape (and the app) won't need to change if
    --    exceptions are added later.
    --    Isolated: a failure here doesn't stop the refresh.
    -------------------------------------------------------------------------
    BEGIN
        INSERT OVERWRITE INTO AI_COST_MGMT.PUBLIC.AI_DASH_COCO_24H
            (USER_NAME, INTERFACE, CREDITS_24H, DAILY_LIMIT, EXCEPTION_EXPIRES_AT, REFRESHED_AT)
        SELECT u.NAME,
               h.INTERFACE,
               SUM(h.TOKEN_CREDITS),
               :default_daily,
               NULL,
               :run_ts
          FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY h
          JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON h.USER_ID = u.USER_ID
         WHERE h.USAGE_TIME >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
         GROUP BY u.NAME, h.INTERFACE;
    EXCEPTION
        WHEN OTHER THEN
            coco_msg := 'failed: ' || SQLERRM;
    END;

    RETURN 'Dashboard refreshed; CoCo 24h ' || coco_msg;
END;
$$;

-- -----------------------------------------------------------------------------
-- Schedule: hourly, a few minutes after the enforcement task so revokes from
-- that run show up. Adjust the minute to suit the enforcement task's schedule.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TASK AI_COST_MGMT.PUBLIC.REFRESH_AI_USAGE_DASHBOARD_TASK
    WAREHOUSE = <XS_WAREHOUSE>
    SCHEDULE  = 'USING CRON 15 * * * * UTC'
    -- "This month" uses the session TIMEZONE parameter, not the cron timezone.
    -- If the enforcement task sets TIMEZONE, set the same value here, e.g.:
    -- TIMEZONE = 'America/Chicago'
AS
    CALL AI_COST_MGMT.PUBLIC.REFRESH_AI_USAGE_DASHBOARD();

ALTER TASK AI_COST_MGMT.PUBLIC.REFRESH_AI_USAGE_DASHBOARD_TASK RESUME;

-- First fill
CALL AI_COST_MGMT.PUBLIC.REFRESH_AI_USAGE_DASHBOARD();

-- Read access for the Streamlit app's owner role (replace <APP_OWNER_ROLE>)
GRANT SELECT ON TABLE AI_COST_MGMT.PUBLIC.AI_DASH_USAGE_DAILY TO ROLE <APP_OWNER_ROLE>;
GRANT SELECT ON TABLE AI_COST_MGMT.PUBLIC.AI_DASH_USER_STATUS TO ROLE <APP_OWNER_ROLE>;
GRANT SELECT ON TABLE AI_COST_MGMT.PUBLIC.AI_DASH_COCO_24H    TO ROLE <APP_OWNER_ROLE>;

-- Sanity check: dashboard totals vs the enforcement query's totals should match
-- SELECT USER_NAME, TIER_ROLE, MONTHLY_CREDIT_LIMIT, CREDITS_USED, STATUS
--   FROM AI_COST_MGMT.PUBLIC.AI_DASH_USER_STATUS ORDER BY CREDITS_USED DESC LIMIT 20;
