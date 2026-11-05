/*==============================================================================
  hourly_revoke_v2.sql: ENFORCE_CORTEX_AI_LIMITS, reworked to also feed the
  self-service usage dashboard
  ------------------------------------------------------------------------------
  Same procedure name and signature as before, so the existing hourly task
  keeps calling it with no change.

  WHAT CHANGED
    1. The six-view usage union now runs ONCE per hour and is saved, per user /
       day / source, to AI_USAGE_DAILY. Enforcement reads that table, and so
       does the dashboard, so the numbers users see are exactly the ones that
       triggered a revoke. The dashboard no longer touches ACCOUNT_USAGE.
    2. A per-user status snapshot (AI_USER_BUDGET_STATUS): tier role, limit,
       credits used this month, ACTIVE / OVER_LIMIT / REVOKED, revoked time.
       Revoked users stay in it (their limit comes from the enforcement log),
       which a grants-based lookup can't do once the role is gone.
    3. Fix: users already revoked this month are no longer revoked and logged
       again. GRANTS_TO_USERS can lag up to ~2 hours, so before this change a
       just-revoked user could be picked up again on the next run(s).
    4. Fix: one failed REVOKE no longer aborts the loop for everyone after it.
       Failures are logged as ACTION = 'REVOKE_FAILED'.
    5. Extra for the dashboard: CoCo usage in the last 24 hours per interface,
       with each user's daily limit (account default, or their active
       exception), so users can tell a daily-limit block from a monthly revoke.
       This step is isolated: if it fails, enforcement still completes.

  UNCHANGED ON PURPOSE
    - Same six sources, same REST API rate table, same > limit rule, same
      session-timezone month boundary (DATE_TRUNC('month', CURRENT_TIMESTAMP())).
    - CoCo is still counted from CORTEX_CODE_CLI_USAGE_HISTORY only. See the
      note at that source if Snowsight and Desktop CoCo should count too.

  CHECK BEFORE RUNNING
    - LOGGED_AT: I don't have the AI_ENFORCEMENT_LOG DDL. Replace LOGGED_AT
      (3 places, all in step 2, marked CHECK) with the log's timestamp column, the one with the
      CURRENT_TIMESTAMP default.
    - admin_db.util.coco_limit_exceptions_active: replace it with wherever the
      exception objects were deployed (1 place, step 4).
    - default_daily (10) should match the account-level CoCo daily limits.
    - Not run against a live account yet. Test in dev first.
==============================================================================*/

USE SCHEMA AI_COST_MGMT.PUBLIC;

-- ---------------------------------------------------------------------------
-- New tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS AI_COST_MGMT.PUBLIC.AI_USAGE_DAILY (
    USAGE_DATE    DATE,
    USER_NAME     VARCHAR,
    SOURCE        VARCHAR,          -- AI Functions / Cortex Analyst / Cortex Agents / Snowflake Intelligence / CoCo CLI / REST API
    CREDITS       NUMBER(38,6),
    REFRESHED_AT  TIMESTAMP_LTZ
);

CREATE TABLE IF NOT EXISTS AI_COST_MGMT.PUBLIC.AI_USER_BUDGET_STATUS (
    USER_NAME             VARCHAR,
    TIER_ROLE             VARCHAR,
    MONTHLY_CREDIT_LIMIT  NUMBER(38,6),
    CREDITS_USED          NUMBER(38,6),
    STATUS                VARCHAR,      -- ACTIVE / OVER_LIMIT / REVOKED
    REVOKED_AT            TIMESTAMP_LTZ,
    MONTH_START           TIMESTAMP_LTZ,
    REFRESHED_AT          TIMESTAMP_LTZ
);

CREATE TABLE IF NOT EXISTS AI_COST_MGMT.PUBLIC.AI_COCO_24H_USAGE (
    USER_NAME             VARCHAR,
    INTERFACE             VARCHAR,
    CREDITS_24H           NUMBER(38,6),
    DAILY_LIMIT           NUMBER,       -- -1 = unlimited
    EXCEPTION_EXPIRES_AT  TIMESTAMP_LTZ,
    REFRESHED_AT          TIMESTAMP_LTZ
);

-- ---------------------------------------------------------------------------
-- Procedure
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE AI_COST_MGMT.PUBLIC.ENFORCE_CORTEX_AI_LIMITS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    month_start    TIMESTAMP_LTZ;
    run_ts         TIMESTAMP_LTZ;
    default_daily  NUMBER  DEFAULT 10;      -- account-level CoCo daily limit
    revoked_cnt    INTEGER DEFAULT 0;
    failed_cnt     INTEGER DEFAULT 0;
    coco_msg       VARCHAR DEFAULT 'ok';
    c CURSOR FOR
        SELECT USER_NAME, TIER_ROLE, CREDITS_USED, MONTHLY_CREDIT_LIMIT
          FROM AI_COST_MGMT.PUBLIC.AI_USER_BUDGET_STATUS
         WHERE STATUS = 'OVER_LIMIT';
BEGIN
    SELECT DATE_TRUNC('month', CURRENT_TIMESTAMP()), CURRENT_TIMESTAMP()
      INTO :month_start, :run_ts;

    -------------------------------------------------------------------------
    -- 1. Month-to-date usage per user / day / source (same sources as before)
    -------------------------------------------------------------------------
    BEGIN TRANSACTION;

    DELETE FROM AI_COST_MGMT.PUBLIC.AI_USAGE_DAILY
     WHERE USAGE_DATE >= :month_start::DATE;

    INSERT INTO AI_COST_MGMT.PUBLIC.AI_USAGE_DAILY (USAGE_DATE, USER_NAME, SOURCE, CREDITS, REFRESHED_AT)
    WITH
    -- Per-model token rates for REST API cost estimation (Table 6b: Cortex Inference with Prompt Caching:
    -- https://www.snowflake.com/legal-files/CreditConsumptionTable.pdf)
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
    src AS (
        SELECT u.NAME AS USER_NAME, h.START_TIME AS TS, 'AI Functions' AS SOURCE, h.CREDITS AS CREDITS
          FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY h
          JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON h.USER_ID = u.USER_ID
         WHERE h.START_TIME >= :month_start

        UNION ALL
        SELECT USERNAME, START_TIME, 'Cortex Analyst', CREDITS
          FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_ANALYST_USAGE_HISTORY
         WHERE START_TIME >= :month_start

        UNION ALL
        SELECT USER_NAME, START_TIME, 'Cortex Agents', TOKEN_CREDITS
          FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
         WHERE START_TIME >= :month_start

        UNION ALL
        SELECT USER_NAME, START_TIME, 'Snowflake Intelligence', TOKEN_CREDITS
          FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY
         WHERE START_TIME >= :month_start

        UNION ALL
        -- NOTE: CLI only, as before. To count CoCo in Snowsight and Desktop too, replace this
        -- block with SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY (all three interfaces,
        -- same USER_ID / USAGE_TIME / TOKEN_CREDITS columns) and label it 'CoCo ' || h.INTERFACE.
        SELECT u.NAME, h.USAGE_TIME, 'CoCo CLI', h.TOKEN_CREDITS
          FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_CLI_USAGE_HISTORY h
          JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON h.USER_ID = u.USER_ID
         WHERE h.USAGE_TIME >= :month_start

        UNION ALL
        -- Cortex REST API (estimated via model_rates: no native TOKEN_CREDITS column)
        SELECT u.NAME, r.START_TIME, 'REST API',
               ROUND(
                   (COALESCE(r.TOKENS_GRANULAR:input::INT,             0) / 1000000.0) * COALESCE(mr.input_rate,       0)
                 + (COALESCE(r.TOKENS_GRANULAR:cache_write_input::INT, 0) / 1000000.0) * COALESCE(mr.cache_write_rate, 0)
                 + (COALESCE(r.TOKENS_GRANULAR:cache_read_input::INT,  0) / 1000000.0) * COALESCE(mr.cache_read_rate,  0)
                 + (COALESCE(r.TOKENS_GRANULAR:output::INT,            0) / 1000000.0) * COALESCE(mr.output_rate,      0)
               , 6)
          FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_REST_API_USAGE_HISTORY r
          LEFT JOIN model_rates mr ON LOWER(r.MODEL_NAME) = LOWER(mr.model_name)
          JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON r.USER_ID = u.USER_ID
         WHERE r.START_TIME >= :month_start
    )
    SELECT TO_TIMESTAMP_LTZ(TS)::DATE, USER_NAME, SOURCE, SUM(CREDITS), :run_ts
      FROM src
     GROUP BY 1, 2, 3;

    COMMIT;

    -------------------------------------------------------------------------
    -- 2. Status snapshot: every tier-role member, plus anyone revoked this
    --    month and not reset since (they no longer hold the role)
    -------------------------------------------------------------------------
    INSERT OVERWRITE INTO AI_COST_MGMT.PUBLIC.AI_USER_BUDGET_STATUS
    WITH
    revoked AS (
        SELECT USER_NAME, TIER_ROLE, LOGGED_AT AS REVOKED_AT              -- CHECK: LOGGED_AT
          FROM AI_COST_MGMT.PUBLIC.AI_ENFORCEMENT_LOG
         WHERE LOGGED_AT >= :month_start                                   -- CHECK: LOGGED_AT
           AND ACTION IN ('REVOKED', 'RESET')
        QUALIFY ROW_NUMBER() OVER (PARTITION BY USER_NAME, TIER_ROLE ORDER BY LOGGED_AT DESC) = 1   -- CHECK: LOGGED_AT
            AND ACTION = 'REVOKED'
    ),
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
          FROM AI_COST_MGMT.PUBLIC.AI_USAGE_DAILY
         WHERE USAGE_DATE >= :month_start::DATE
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
      LEFT JOIN revoked r ON m.USER_NAME = r.USER_NAME AND m.TIER_ROLE = r.TIER_ROLE;

    -------------------------------------------------------------------------
    -- 3. Enforce: revoke OVER_LIMIT users (already-revoked users are excluded)
    -------------------------------------------------------------------------
    FOR rec IN c DO
        LET v_user    VARCHAR       := rec.USER_NAME;
        LET v_role    VARCHAR       := rec.TIER_ROLE;
        LET v_credits NUMBER(38,6)  := rec.CREDITS_USED;
        LET v_limit   NUMBER(38,6)  := rec.MONTHLY_CREDIT_LIMIT;
        BEGIN
            EXECUTE IMMEDIATE 'REVOKE ROLE ' || :v_role || ' FROM USER "' || :v_user || '"';
            INSERT INTO AI_COST_MGMT.PUBLIC.AI_ENFORCEMENT_LOG
                (USER_NAME, TIER_ROLE, ACTION, CREDITS_USED, CREDIT_LIMIT)
            VALUES (:v_user, :v_role, 'REVOKED', :v_credits, :v_limit);
            UPDATE AI_COST_MGMT.PUBLIC.AI_USER_BUDGET_STATUS
               SET STATUS = 'REVOKED', REVOKED_AT = CURRENT_TIMESTAMP()
             WHERE USER_NAME = :v_user AND TIER_ROLE = :v_role;
            revoked_cnt := revoked_cnt + 1;
        EXCEPTION
            WHEN OTHER THEN
                failed_cnt := failed_cnt + 1;
                INSERT INTO AI_COST_MGMT.PUBLIC.AI_ENFORCEMENT_LOG
                    (USER_NAME, TIER_ROLE, ACTION, CREDITS_USED, CREDIT_LIMIT)
                VALUES (:v_user, :v_role, 'REVOKE_FAILED', :v_credits, :v_limit);
        END;
    END FOR;

    -------------------------------------------------------------------------
    -- 4. Dashboard extra: CoCo usage in the last 24h per interface vs the
    --    daily limit. Isolated so a failure here never affects enforcement.
    -------------------------------------------------------------------------
    BEGIN
        INSERT OVERWRITE INTO AI_COST_MGMT.PUBLIC.AI_COCO_24H_USAGE
        WITH ex AS (
            SELECT USER_NAME,
                   IFF(MIN(LIMIT_VALUE) = -1, -1, MAX(LIMIT_VALUE)) AS LIMIT_VALUE,   -- same "highest wins, -1 beats all" rule
                   MAX(EXPIRES_AT) AS EXPIRES_AT
              FROM admin_db.util.coco_limit_exceptions_active                       -- CHECK: deployed location
             GROUP BY USER_NAME
        )
        SELECT u.NAME,
               h.INTERFACE,
               SUM(h.TOKEN_CREDITS),
               COALESCE(ex.LIMIT_VALUE, :default_daily),
               ex.EXPIRES_AT,
               :run_ts
          FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY h
          JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON h.USER_ID = u.USER_ID
          LEFT JOIN ex ON ex.USER_NAME = u.NAME
         WHERE h.USAGE_TIME >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
         GROUP BY u.NAME, h.INTERFACE, ex.LIMIT_VALUE, ex.EXPIRES_AT;
    EXCEPTION
        WHEN OTHER THEN
            coco_msg := 'failed: ' || SQLERRM;
    END;

    RETURN 'Enforcement complete: revoked ' || revoked_cnt || ', failed ' || failed_cnt
        || '; CoCo 24h refresh ' || coco_msg;
END;
$$;

-- Read access for the Streamlit app's owner role (replace <APP_OWNER_ROLE>)
-- GRANT SELECT ON TABLE AI_COST_MGMT.PUBLIC.AI_USER_BUDGET_STATUS TO ROLE <APP_OWNER_ROLE>;
-- GRANT SELECT ON TABLE AI_COST_MGMT.PUBLIC.AI_USAGE_DAILY        TO ROLE <APP_OWNER_ROLE>;
-- GRANT SELECT ON TABLE AI_COST_MGMT.PUBLIC.AI_COCO_24H_USAGE     TO ROLE <APP_OWNER_ROLE>;
