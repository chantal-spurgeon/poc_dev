/*==============================================================================
  reset_ai_v2.sql: RESET_ALL_AI_ACCESS with one fix
  ------------------------------------------------------------------------------
  FIX: re-grant everyone revoked last month, from the enforcement log.
    The procedure finds "members without an AI role" from GRANTS_TO_USERS,
    which can lag up to ~2 hours. A user revoked late on the last day of the
    month can still look like they hold the role when this runs on the 1st,
    so they were skipped and stayed locked out for another whole month.
    Granting a role the user already has is harmless, so revoked users are
    now always included. The result is de-duplicated so nobody is granted or
    logged twice.

  Everything else is the same logic as reset_ai.sql (switched to $$ quoting
  for readability).

  CHECK BEFORE RUNNING
    - LOGGED_AT (1 place): replace with AI_ENFORCEMENT_LOG's timestamp column.
    - Run the reset in the same session timezone as the hourly enforcement,
      or "last month" here and "this month" there won't line up.
==============================================================================*/

CREATE OR REPLACE PROCEDURE AI_COST_MGMT.PUBLIC.RESET_ALL_AI_ACCESS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
    LET result VARCHAR DEFAULT 'Reset complete';
    LET c CURSOR FOR

        WITH

        -- Manually assign users a specific AI role. Add entries here as needed.
        manual_assignments AS (
            SELECT column1 AS USER_NAME, column2 AS TIER_ROLE
            FROM VALUES
                ('ZUCKMAND@CHOP.EDU', 'AI_DATA_SCIENCE'),
                ('HARRAZM@CHOP.EDU',  'AI_DATA_SCIENCE')
        ),

        -- Get list of DnA roles
        dna_members AS (
            SELECT NAME AS ROLE
            FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES
            WHERE DELETED_ON IS NULL
                AND NAME LIKE '%DNA%'
                AND NAME NOT LIKE '%NON_DNA%'
        ),

        -- All members that should have an AI role
        role_members AS (
            SELECT g.GRANTEE_NAME AS USER_NAME, g.ROLE AS TIER_ROLE
            FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS g
            JOIN dna_members d ON g.ROLE = d.ROLE
            WHERE g.DELETED_ON IS NULL
                AND g.GRANTEE_NAME LIKE '%CHOP.EDU'
                AND g.GRANTEE_NAME NOT LIKE 'SVC_%'
                AND g.GRANTEE_NAME NOT LIKE 'E_%'
        ),

        members_with_an_ai_role AS (
            SELECT GRANTEE_NAME AS USER_NAME, ROLE AS TIER_ROLE
            FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
            WHERE ROLE IN ('AI_EXPLORER', 'AI_DATA_SCIENCE') AND DELETED_ON IS NULL
        ),

        -- Members in role_members who are not in members_with_an_ai_role
        members_without_an_ai_role AS (
            SELECT rm.USER_NAME, rm.TIER_ROLE
            FROM role_members rm
            LEFT JOIN members_with_an_ai_role mw ON rm.USER_NAME = mw.USER_NAME
            WHERE mw.USER_NAME IS NULL
        ),

        -- NEW: everyone revoked by enforcement last month gets their role back,
        -- even if GRANTS_TO_USERS hasn't caught up with the revoke yet
        revoked_last_month AS (
            SELECT USER_NAME, TIER_ROLE
            FROM AI_COST_MGMT.PUBLIC.AI_ENFORCEMENT_LOG
            WHERE ACTION = 'REVOKED'
                AND LOGGED_AT >= DATEADD('month', -1, DATE_TRUNC('month', CURRENT_TIMESTAMP()))   -- CHECK: LOGGED_AT
        )

        SELECT DISTINCT USER_NAME, TIER_ROLE FROM (
            -- data science role for DNA_DATA_SCIENTISTS, explorer role for all other DNA roles
            SELECT USER_NAME,
                   IFF(TIER_ROLE = 'DNA_DATA_SCIENTISTS', 'AI_DATA_SCIENCE', 'AI_EXPLORER') AS TIER_ROLE
            FROM members_without_an_ai_role

            UNION ALL
            SELECT USER_NAME, TIER_ROLE FROM manual_assignments

            UNION ALL
            SELECT USER_NAME, TIER_ROLE FROM revoked_last_month
        );

    FOR rec IN c DO
        LET v_user VARCHAR := rec.USER_NAME;
        LET v_role VARCHAR := rec.TIER_ROLE;

        EXECUTE IMMEDIATE 'GRANT ROLE ' || :v_role || ' TO USER "' || :v_user || '"';
        INSERT INTO AI_COST_MGMT.PUBLIC.AI_ENFORCEMENT_LOG
            (USER_NAME, TIER_ROLE, ACTION, CREDITS_USED, CREDIT_LIMIT)
        VALUES (:v_user, :v_role, 'RESET', 0, 0);
    END FOR;
    RETURN :result;
END;
$$;
