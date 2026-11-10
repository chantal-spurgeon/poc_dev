-- PREVIEW for RESET_ALL_AI_ACCESS VERSION 1 (current configuration, DNA roles only)
-- Read-only: lists who the reset would grant a role to, and which role.
-- Run it before deploying (or before the one-time rollout CALL) and review the list.
-- Needs AI_COST_MGMT.PUBLIC.AI_QUOTA_EXCEPTION_LOG to exist.


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
