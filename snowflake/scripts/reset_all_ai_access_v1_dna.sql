-- RESET_ALL_AI_ACCESS, VERSION 1 (current configuration, DNA roles only)
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
-- VERSION 1: current configuration (reset_scope = "dna"). Only members of DNA
-- roles get a tier role back: DNA_DATA_SCIENTISTS -> AI_DATA_SCIENCE, other
-- DNA roles -> AI_EXPLORER, plus the manual assignments.
--
-- Based on the prod procedure (scripts/reset_ai.sql, removed from scripts/ in
-- the Nov 5 cleanup), with these changes (README, AI cost management unit):
--   1. A tier role held only through an active monthly-quota exception
--      (AI_QUOTA_EXCEPTION_LOG) does not count as having an AI role, so a user
--      whose AI_EXPLORER was revoked still gets it back on the 1st.
--   2. 'SVC_%' and 'E_%' became STARTSWITH: in LIKE, _ matches any character,
--      so 'E_%' excluded every user whose name starts with E.
--   3. One role per user: a user in DNA_DATA_SCIENTISTS and another DNA role
--      gets AI_DATA_SCIENCE only (before, both). Manually assigned users get
--      only their manual role.
--   4. One failed GRANT no longer stops the loop; failures are counted and
--      named in the return value (see TASK_HISTORY).
-- Needs AI_COST_MGMT.PUBLIC.AI_QUOTA_EXCEPTION_LOG to exist.
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

        -- Get list of DnA roles
        dna_members AS (
            SELECT NAME AS ROLE
            FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES
            WHERE DELETED_ON IS NULL
                AND NAME LIKE '%DNA%'
                AND NAME NOT LIKE '%NON_DNA%'
        ),

        -- Members of DnA roles who should have an AI role
        role_members AS (
            SELECT g.GRANTEE_NAME AS USER_NAME, g.ROLE AS DNA_ROLE
            FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS g
            JOIN dna_members d ON g.ROLE = d.ROLE
            WHERE g.DELETED_ON IS NULL
                AND g.GRANTEE_NAME LIKE '%CHOP.EDU'
                AND NOT STARTSWITH(g.GRANTEE_NAME, 'SVC_')
                AND NOT STARTSWITH(g.GRANTEE_NAME, 'E_')
        ),

        -- Users who already hold a tier role. A role held only through an
        -- active monthly-quota exception doesn't count.
        members_with_an_ai_role AS (
            SELECT g.GRANTEE_NAME AS USER_NAME, g.ROLE AS TIER_ROLE
            FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS g
            WHERE g.ROLE IN ('AI_EXPLORER', 'AI_DATA_SCIENCE')
                AND g.DELETED_ON IS NULL
                AND NOT EXISTS (
                    SELECT 1
                      FROM AI_COST_MGMT.PUBLIC.AI_QUOTA_EXCEPTION_LOG e
                     WHERE e.USER_NAME    = g.GRANTEE_NAME
                       AND e.GRANTED_ROLE = g.ROLE
                       AND e.STATUS       = 'ACTIVE')
        ),

        -- DnA members without a tier role, one role each:
        -- DNA_DATA_SCIENTISTS -> AI_DATA_SCIENCE, any other DNA role -> AI_EXPLORER
        members_without_an_ai_role AS (
            SELECT rm.USER_NAME,
                   IFF(MAX(IFF(rm.DNA_ROLE = 'DNA_DATA_SCIENTISTS', 1, 0)) = 1,
                       'AI_DATA_SCIENCE', 'AI_EXPLORER') AS TIER_ROLE
            FROM role_members rm
            LEFT JOIN members_with_an_ai_role mw ON rm.USER_NAME = mw.USER_NAME
            WHERE mw.USER_NAME IS NULL
                AND rm.USER_NAME NOT IN (SELECT USER_NAME FROM manual_assignments)
            GROUP BY rm.USER_NAME
        )

        SELECT USER_NAME, TIER_ROLE FROM members_without_an_ai_role

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
