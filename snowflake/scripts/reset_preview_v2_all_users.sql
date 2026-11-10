-- PREVIEW for RESET_ALL_AI_ACCESS VERSION 2 (after rollout, all eligible users)
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
