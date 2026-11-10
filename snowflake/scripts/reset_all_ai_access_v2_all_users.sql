-- RESET_ALL_AI_ACCESS, VERSION 2 (after rollout, all eligible users)
-- Prod deployment, rendered from snowflake/terragrunt-v2 (ai_cost_mgmt unit).
-- Run as the role that owns the existing procedure and the reset task.
-- Requires AI_COST_MGMT.PUBLIC.AI_QUOTA_EXCEPTION_LOG to exist.
-- CREATE OR REPLACE keeps the name and signature, so the task keeps calling it.
-- Check first: SELECT GET_DDL('PROCEDURE', 'AI_COST_MGMT.PUBLIC.RESET_ALL_AI_ACCESS()');
--   and keep a copy of the current version for rollback.

CREATE OR REPLACE PROCEDURE AI_COST_MGMT.PUBLIC.RESET_ALL_AI_ACCESS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
-- Procedure body for RESET_ALL_AI_ACCESS (rendered by templatefile()).
-- VERSION 2: after the rollout (reset_scope = "all_users"). Every eligible
-- user without a tier role gets one: AI_EXPLORER, or AI_DATA_SCIENCE for
-- members of DNA_DATA_SCIENTISTS, plus the manual assignments. Monthly-quota
-- exceptions grant AI_DATA_SCIENCE on top of that.
--
-- The same query does the one-time rollout: deploy this version and run
-- CALL ...RESET_ALL_AI_ACCESS(); once by hand (README). Run the preview query
-- first to see who will get which role.
--
-- AI_DATA_SCIENCE as a permanent role: kept for DNA_DATA_SCIENTISTS and the
-- manual assignments, as today. To make it exception-only, empty
-- manual_assignments and remove the dna_data_scientists join below.
--
-- Same fixes as version 1 (exception filter, STARTSWITH, one role per user,
-- per-user error handling). Needs AI_COST_MGMT.PUBLIC.AI_QUOTA_EXCEPTION_LOG.
BEGIN
    LET n_ok NUMBER DEFAULT 0;
    LET n_failed NUMBER DEFAULT 0;
    LET failed_users VARCHAR DEFAULT '';

    LET c CURSOR FOR

        WITH

        -- Manually assign users a specific AI role — add entries here as needed
        manual_assignments AS (
            SELECT column1 AS USER_NAME, column2 AS TIER_ROLE
            FROM VALUES
                ('ZUCKMAND@CHOP.EDU',  'AI_DATA_SCIENCE'),
                ('HARRAZM@CHOP.EDU', 'AI_DATA_SCIENCE')
        ),

        -- Members of DNA_DATA_SCIENTISTS get AI_DATA_SCIENCE as their normal role
        dna_data_scientists AS (
            SELECT DISTINCT GRANTEE_NAME AS USER_NAME
            FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
            WHERE ROLE = 'DNA_DATA_SCIENTISTS'
                AND DELETED_ON IS NULL
        ),

        -- Everyone who should have an AI role: active, enabled people in the
        -- CHOP.EDU domain, not service or E_ accounts.
        eligible_users AS (
            SELECT NAME AS USER_NAME
            FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
            WHERE DELETED_ON IS NULL
                AND NOT COALESCE(TRY_TO_BOOLEAN(DISABLED::VARCHAR), FALSE)
                AND COALESCE(TYPE, 'PERSON') = 'PERSON'               -- CHECK: excludes SERVICE / LEGACY_SERVICE users
                AND NAME LIKE '%CHOP.EDU'
                AND NOT STARTSWITH(NAME, 'SVC_')
                AND NOT STARTSWITH(NAME, 'E_')
        ),

        -- Users who already hold a tier role. A role held only through an
        -- active monthly-quota exception doesn't count.
        members_with_an_ai_role AS (
            SELECT g.GRANTEE_NAME AS USER_NAME
            FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS g
            WHERE g.ROLE IN ('AI_EXPLORER', 'AI_DATA_SCIENCE')
                AND g.DELETED_ON IS NULL
                AND NOT EXISTS (
                    SELECT 1
                      FROM AI_COST_MGMT.PUBLIC.AI_QUOTA_EXCEPTION_LOG e
                     WHERE e.USER_NAME    = g.GRANTEE_NAME
                       AND e.GRANTED_ROLE = g.ROLE
                       AND e.STATUS       = 'ACTIVE')
        )

        SELECT eu.USER_NAME,
               IFF(ds.USER_NAME IS NOT NULL, 'AI_DATA_SCIENCE', 'AI_EXPLORER') AS TIER_ROLE
        FROM eligible_users eu
        LEFT JOIN dna_data_scientists ds ON eu.USER_NAME = ds.USER_NAME
        WHERE NOT EXISTS (SELECT 1 FROM members_with_an_ai_role mw WHERE mw.USER_NAME = eu.USER_NAME)
            AND eu.USER_NAME NOT IN (SELECT USER_NAME FROM manual_assignments)

        UNION ALL

        -- include manually assigned users with their explicitly specified role
        SELECT USER_NAME, TIER_ROLE FROM manual_assignments;

    FOR rec IN c DO
        LET v_user VARCHAR := rec.USER_NAME;
        LET v_role VARCHAR := rec.TIER_ROLE;
        BEGIN
            EXECUTE IMMEDIATE
              'GRANT ROLE ' || :v_role
              || ' TO USER "' || REPLACE(:v_user, '"', '""') || '"';
            INSERT INTO AI_COST_MGMT.PUBLIC.AI_ENFORCEMENT_LOG
              (USER_NAME, TIER_ROLE, ACTION, CREDITS_USED, CREDIT_LIMIT)
            VALUES (:v_user, :v_role, 'RESET', 0, 0);
            n_ok := n_ok + 1;
        EXCEPTION
            WHEN OTHER THEN
                n_failed := n_failed + 1;
                failed_users := failed_users || ' ' || v_user;
        END;
    END FOR;

    RETURN 'Reset complete: ' || n_ok || ' granted, ' || n_failed || ' failed'
           || IFF(n_failed > 0, ' (' || TRIM(failed_users) || ')', '');
END
$$;
