/*==============================================================================
  CoCo daily credit limit: role-based exception
  ------------------------------------------------------------------------------
  PURPOSE
    The three Cortex Code (CoCo) daily credit limits are set at the account
    level (currently 10 credits per user per rolling 24 hours):

      CORTEX_CODE_SNOWSIGHT_DAILY_EST_CREDIT_LIMIT_PER_USER
      CORTEX_CODE_CLI_DAILY_EST_CREDIT_LIMIT_PER_USER
      CORTEX_CODE_DESKTOP_DAILY_EST_CREDIT_LIMIT_PER_USER

    Snowflake only lets you set these on the ACCOUNT or on individual USERS.
    They can't be set on a role. A user-level value overrides the account
    value for that user only.

    This script gives one role (a set of users) a different limit. It does
    that by setting the user-level override on every user granted the role,
    and keeps it in sync on a schedule:
      - users who join the role get the higher limit at the next run
      - users who leave the role are UNSET back to the account default

  HOW TO USE
    1. Search and replace the placeholders below:
         admin_db.util      -> a database.schema you use for admin objects
         admin_wh           -> a warehouse for the task (an XS is plenty)
         COCO_POWER_USERS   -> the role that gets the exception
         50                 -> the exception limit (-1 = unlimited, 0 = blocked)
    2. Run sections 1-4 in order using a role that can change user parameters
       (ACCOUNTADMIN, or a role with enough privileges on the user objects).
    3. Check the results with the queries in section 5.
    4. TEST IN A NON-PRODUCTION ACCOUNT FIRST. This script hasn't been run
       against a live account.

  KNOWN LIMITATIONS
    - Direct grants only. SHOW GRANTS OF ROLE lists only users granted the
      role directly. Users who get it through another role are NOT covered.
      See the optional variant in section 6 to include them.
    - Timing. A new member stays at the account limit until the next task run.
      Run EXECUTE TASK to apply right away.
    - Overlapping exceptions. If one user is in two exception roles synced by
      separate tasks, whichever task runs last sets that user's limit, and
      leaving one role resets them to the account default even though they
      still hold the other.
    - Estimated credits. Snowflake doesn't document how the estimate is
      calculated or how often it refreshes. Treat the limit as a soft ceiling.
    - Manual overrides. If you also set overrides by hand with ALTER USER,
      this procedure won't touch those users unless they're in the role.
      If they are in the role, the procedure overwrites the manual value.
==============================================================================*/


/*------------------------------------------------------------------------------
  SECTION 1: Context
------------------------------------------------------------------------------*/
USE ROLE ACCOUNTADMIN;          -- or your delegated admin role
USE WAREHOUSE admin_wh;

-- Optional: confirm the current account-level values (expect 10)
SHOW PARAMETERS LIKE 'CORTEX_CODE%DAILY_EST_CREDIT_LIMIT_PER_USER' IN ACCOUNT;


/*------------------------------------------------------------------------------
  SECTION 2: Tracking table
  Records which users this process has given an override, and for which role.
  The procedure uses it to find users who have since left the role, so their
  override can be removed.
------------------------------------------------------------------------------*/
CREATE TABLE IF NOT EXISTS admin_db.util.coco_limit_overrides (
    user_name  STRING,         -- Snowflake user name, as SHOW GRANTS returns it
    role_name  STRING,         -- exception role that granted the override
    set_at     TIMESTAMP_LTZ   -- when the override was last applied
);


/*------------------------------------------------------------------------------
  SECTION 3: Sync procedure
  Arguments:
    P_ROLE   the role whose direct user grantees get the exception
    P_LIMIT  the limit to apply on all three surfaces
             (-1 = unlimited, 0 = blocked, n = n credits per rolling 24h)

  Steps:
    1. List the role's current direct user members.
    2. Set all three limits on each member (ALTER USER ... SET).
    3. For anyone tracked from an earlier run who is no longer a member,
       UNSET all three limits so they go back to the account default.
    4. Rewrite the tracking table with the current membership.

  EXECUTE AS CALLER: when the task calls the procedure, it runs with the task
  owner's privileges, so the task owner needs the right to change users.
------------------------------------------------------------------------------*/
CREATE OR REPLACE PROCEDURE admin_db.util.sync_coco_limit_exception(
    p_role  STRING,
    p_limit NUMBER
)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  n_set   INTEGER DEFAULT 0;
  n_unset INTEGER DEFAULT 0;
BEGIN
  -- Step 1: current direct members of the role
  EXECUTE IMMEDIATE 'SHOW GRANTS OF ROLE "' || p_role || '"';
  CREATE OR REPLACE TEMPORARY TABLE coco_role_members AS
    SELECT "grantee_name" AS user_name
    FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
    WHERE "granted_to" = 'USER';

  -- Step 2: apply the exception limit to every member
  LET members CURSOR FOR SELECT user_name FROM coco_role_members;
  FOR m IN members DO
    LET u STRING := m.user_name;
    EXECUTE IMMEDIATE 'ALTER USER "' || u || '" SET '
      || 'CORTEX_CODE_SNOWSIGHT_DAILY_EST_CREDIT_LIMIT_PER_USER = ' || p_limit
      || ' CORTEX_CODE_CLI_DAILY_EST_CREDIT_LIMIT_PER_USER = '     || p_limit
      || ' CORTEX_CODE_DESKTOP_DAILY_EST_CREDIT_LIMIT_PER_USER = ' || p_limit;
    n_set := n_set + 1;
  END FOR;

  -- Step 3: users who left the role go back to the account default
  LET rs RESULTSET := (
    SELECT o.user_name
    FROM admin_db.util.coco_limit_overrides o
    WHERE o.role_name = :p_role
      AND o.user_name NOT IN (SELECT user_name FROM coco_role_members)
  );
  LET stale CURSOR FOR rs;
  FOR s IN stale DO
    LET u STRING := s.user_name;
    EXECUTE IMMEDIATE 'ALTER USER "' || u || '" UNSET '
      || 'CORTEX_CODE_SNOWSIGHT_DAILY_EST_CREDIT_LIMIT_PER_USER, '
      || 'CORTEX_CODE_CLI_DAILY_EST_CREDIT_LIMIT_PER_USER, '
      || 'CORTEX_CODE_DESKTOP_DAILY_EST_CREDIT_LIMIT_PER_USER';
    n_unset := n_unset + 1;
  END FOR;

  -- Step 4: refresh the tracking table for this role
  DELETE FROM admin_db.util.coco_limit_overrides WHERE role_name = :p_role;
  INSERT INTO admin_db.util.coco_limit_overrides
    SELECT user_name, :p_role, CURRENT_TIMESTAMP() FROM coco_role_members;

  RETURN n_set || ' user(s) set to ' || p_limit || ', '
      || n_unset || ' user(s) reset to account default';
END;
$$;

-- Run once by hand to check the output before scheduling
CALL admin_db.util.sync_coco_limit_exception('COCO_POWER_USERS', 50);


/*------------------------------------------------------------------------------
  SECTION 4: Schedule it
  Runs at the top of every hour, Central time. Change the cron to suit.
  Tasks are created suspended, so RESUME is required.
------------------------------------------------------------------------------*/
CREATE OR REPLACE TASK admin_db.util.sync_coco_limits_task
  WAREHOUSE = admin_wh
  SCHEDULE  = 'USING CRON 0 * * * * America/Chicago'
  COMMENT   = 'Keeps CoCo daily credit limit exception in sync with role COCO_POWER_USERS'
AS
  CALL admin_db.util.sync_coco_limit_exception('COCO_POWER_USERS', 50);

ALTER TASK admin_db.util.sync_coco_limits_task RESUME;

-- To apply immediately after adding someone to the role:
-- EXECUTE TASK admin_db.util.sync_coco_limits_task;


/*------------------------------------------------------------------------------
  SECTION 5: Verify
------------------------------------------------------------------------------*/
-- Who the process has given the exception to
SELECT * FROM admin_db.util.coco_limit_overrides ORDER BY role_name, user_name;

-- Spot-check one user: LEVEL should read USER and VALUE should be 50
SHOW PARAMETERS LIKE 'CORTEX_CODE%DAILY_EST_CREDIT_LIMIT_PER_USER' IN USER jsmith;

-- Task run history (last 24 hours)
SELECT name, state, scheduled_time, completed_time, return_value, error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
       TASK_NAME => 'SYNC_COCO_LIMITS_TASK',
       SCHEDULED_TIME_RANGE_START => DATEADD('hour', -24, CURRENT_TIMESTAMP())))
ORDER BY scheduled_time DESC;


/*------------------------------------------------------------------------------
  SECTION 6 (OPTIONAL): Include users who get the role through another role
  To include users who hold COCO_POWER_USERS through a parent role, replace
  Step 1 in the procedure with a query on ACCOUNT_USAGE. Notes:
    - ACCOUNT_USAGE can lag by up to about 2 hours.
    - The caller needs access to the SNOWFLAKE database
      (for example, IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE).
    - The recursive CTE walks role-to-role grants down to users.

  Replacement for Step 1:

  CREATE OR REPLACE TEMPORARY TABLE coco_role_members AS
    WITH RECURSIVE role_tree (role_name) AS (
      SELECT :p_role
      UNION ALL
      SELECT g.grantee_name
      FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES g
      JOIN role_tree rt ON g.name = rt.role_name
      WHERE g.granted_on = 'ROLE'
        AND g.privilege  = 'USAGE'
        AND g.granted_to = 'ROLE'
        AND g.deleted_on IS NULL
    )
    SELECT DISTINCT u.grantee_name AS user_name
    FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS u
    JOIN role_tree rt ON u.role = rt.role_name
    WHERE u.deleted_on IS NULL;
------------------------------------------------------------------------------*/


/*------------------------------------------------------------------------------
  SECTION 7: Rollback / remove the exception entirely
  Run these to switch everything back to the account default and remove the
  objects this script created.
------------------------------------------------------------------------------*/
-- ALTER TASK admin_db.util.sync_coco_limits_task SUSPEND;
--
-- -- Reset every tracked user to the account default:
-- EXECUTE IMMEDIATE $$
-- DECLARE
--   c CURSOR FOR SELECT DISTINCT user_name FROM admin_db.util.coco_limit_overrides;
-- BEGIN
--   FOR r IN c DO
--     LET u STRING := r.user_name;
--     EXECUTE IMMEDIATE 'ALTER USER "' || u || '" UNSET '
--       || 'CORTEX_CODE_SNOWSIGHT_DAILY_EST_CREDIT_LIMIT_PER_USER, '
--       || 'CORTEX_CODE_CLI_DAILY_EST_CREDIT_LIMIT_PER_USER, '
--       || 'CORTEX_CODE_DESKTOP_DAILY_EST_CREDIT_LIMIT_PER_USER';
--   END FOR;
--   RETURN 'reset complete';
-- END;
-- $$;
--
-- DROP TASK      admin_db.util.sync_coco_limits_task;
-- DROP PROCEDURE admin_db.util.sync_coco_limit_exception(STRING, NUMBER);
-- DROP TABLE     admin_db.util.coco_limit_overrides;
