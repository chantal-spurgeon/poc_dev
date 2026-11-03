/*==============================================================================
  CoCo daily credit limit exceptions: approval procedures + 30-day auto-expiry
  ------------------------------------------------------------------------------
  PURPOSE
    The three Cortex Code (CoCo) daily credit limits are set at the account
    level (currently 10 credits per user per rolling 24 hours):

      CORTEX_CODE_SNOWSIGHT_DAILY_EST_CREDIT_LIMIT_PER_USER
      CORTEX_CODE_CLI_DAILY_EST_CREDIT_LIMIT_PER_USER
      CORTEX_CODE_DESKTOP_DAILY_EST_CREDIT_LIMIT_PER_USER

    Snowflake only lets you set these on the ACCOUNT or on individual USERS.
    This script lets your approval UI grant a temporary exception to one user,
    or to every user in a role, when a manager clicks Accept. Each exception
    expires automatically, 30 days by default.

  WHAT THE UI CALLS
    Grant (Accept button):
      CALL admin_db.util.coco_grant_limit_exception(
             '<USER|ROLE>', '<name>', <limit>, '<approver>'
             [, '<reason>' [, <days>]]);

    Revoke early (optional "Revoke" button):
      CALL admin_db.util.coco_revoke_limit_exception('<request_id>', '<revoker>');

    Both return a JSON object the UI can display, for example:
      {"status":"OK","request_id":"...","users":["JSMITH"],"limit":50,
       "expires_at":"2026-12-03 10:15:00"}
      {"status":"ERROR","message":"..."}

  HOW IT WORKS
    1. Every approval writes one row per affected user to a log table.
       A role request is expanded to its users (including users who get the
       role through other roles) at the moment of approval.
    2. A helper procedure works out each user's EFFECTIVE limit from that
       user's ACTIVE log rows and applies it:
         - no active exceptions        -> UNSET (back to the account default)
         - one or more active          -> the highest limit wins
                                          (-1 / unlimited beats any number)
       Because the limit is always recalculated from the log, overlapping
       exceptions (for example a user exception and a role exception) never
       wipe each other out.
    3. An hourly task marks rows past expires_at as EXPIRED and recalculates
       those users. A user is reset at most about an hour after their 30 days.

  OBJECTS CREATED
    admin_db.util.coco_limit_exception_log      log table (audit trail)
    admin_db.util.coco_limit_exceptions_active  view of current exceptions (for the UI)
    admin_db.util.coco_apply_effective_limit    helper (internal, not granted to UI)
    admin_db.util.coco_grant_limit_exception    called by the UI's Accept button
    admin_db.util.coco_revoke_limit_exception   optional early revoke
    admin_db.util.coco_expire_limit_exceptions  called by the task
    admin_db.util.coco_expire_limit_exceptions_task   hourly expiry task

  PLACEHOLDERS (search and replace before running)
    admin_db.util       database.schema for admin objects
    admin_wh            warehouse for the expiry task
    COCO_LIMIT_ADMIN    role that OWNS the procedures and the task. It must be
                        able to change these parameters on users (ACCOUNTADMIN,
                        or a role with enough privileges on the user objects)
                        and to run SHOW USERS / SHOW GRANTS OF ROLE.
    COCO_EXCEPTION_UI   role the UI's service user connects with. It gets
                        only USAGE on the grant/revoke procedures and SELECT
                        on the view, and needs no ALTER USER rights itself.

  IMPORTANT
    - TEST IN A NON-PRODUCTION ACCOUNT FIRST. This script hasn't been run
      against a live account. Owner's-rights procedures have restrictions;
      if SHOW commands fail inside them in your account, switch the
      procedures to EXECUTE AS CALLER and give the UI role the needed
      privileges instead.
    - Don't run this alongside the earlier hourly "role sync" script. Both
      would set the same parameters and fight each other.
    - Make every exception go through these procedures. When a user's last
      active exception ends, the helper UNSETs all three parameters, which
      also removes any override someone set by hand.
    - Role requests are a snapshot. Users added to the role after approval
      are NOT covered (submit a new request). Users removed from the role keep
      the exception until it expires or is revoked.
==============================================================================*/


/*------------------------------------------------------------------------------
  SECTION 1: Context
------------------------------------------------------------------------------*/
USE ROLE COCO_LIMIT_ADMIN;
USE WAREHOUSE admin_wh;


/*------------------------------------------------------------------------------
  SECTION 2: Log table
  One row per user per approved request. A ROLE request for a role with 12
  users writes 12 rows that share one request_id.
  status: ACTIVE  -> in force until expires_at
          EXPIRED -> ended by the expiry task
          REVOKED -> ended early by coco_revoke_limit_exception
------------------------------------------------------------------------------*/
CREATE TABLE IF NOT EXISTS admin_db.util.coco_limit_exception_log (
    exception_id  NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    request_id    STRING,          -- one per Accept click
    target_type   STRING,          -- USER or ROLE (what the manager approved)
    target_name   STRING,          -- the user or role named in the request
    user_name     STRING,          -- the user this row's override applies to
    limit_value   NUMBER,          -- -1 = unlimited, n = n credits per 24h
    approved_by   STRING,          -- passed in by the UI
    reason        STRING,          -- passed in by the UI (optional)
    granted_at    TIMESTAMP_LTZ,
    expires_at    TIMESTAMP_LTZ,
    status        STRING,          -- ACTIVE / EXPIRED / REVOKED
    ended_at      TIMESTAMP_LTZ,
    ended_by      STRING           -- revoker name, or 'EXPIRY_TASK'
);


/*------------------------------------------------------------------------------
  SECTION 3: Helper: apply a user's effective limit
  Recalculates one user's limit from their ACTIVE, unexpired log rows and
  applies it. Every other procedure calls this, so the rule for combining
  exceptions lives in one place.
  Internal only: don't grant it to the UI role.
------------------------------------------------------------------------------*/
CREATE OR REPLACE PROCEDURE admin_db.util.coco_apply_effective_limit(p_user STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  n_active NUMBER;
  eff      NUMBER;
  quoted   STRING;
BEGIN
  -- Highest active limit wins; -1 (unlimited) beats any number
  SELECT COUNT(*),
         IFF(MAX(IFF(limit_value = -1, 1, 0)) = 1, -1, MAX(limit_value))
    INTO :n_active, :eff
    FROM admin_db.util.coco_limit_exception_log
   WHERE user_name  = :p_user
     AND status     = 'ACTIVE'
     AND expires_at > CURRENT_TIMESTAMP();

  quoted := '"' || REPLACE(p_user, '"', '""') || '"';

  IF (n_active = 0) THEN
    -- No exceptions left: return the user to the account default
    EXECUTE IMMEDIATE 'ALTER USER ' || quoted || ' UNSET '
      || 'CORTEX_CODE_SNOWSIGHT_DAILY_EST_CREDIT_LIMIT_PER_USER, '
      || 'CORTEX_CODE_CLI_DAILY_EST_CREDIT_LIMIT_PER_USER, '
      || 'CORTEX_CODE_DESKTOP_DAILY_EST_CREDIT_LIMIT_PER_USER';
    RETURN 'UNSET';
  ELSE
    EXECUTE IMMEDIATE 'ALTER USER ' || quoted || ' SET '
      || 'CORTEX_CODE_SNOWSIGHT_DAILY_EST_CREDIT_LIMIT_PER_USER = ' || eff
      || ' CORTEX_CODE_CLI_DAILY_EST_CREDIT_LIMIT_PER_USER = '     || eff
      || ' CORTEX_CODE_DESKTOP_DAILY_EST_CREDIT_LIMIT_PER_USER = ' || eff;
    RETURN 'SET ' || eff;
  END IF;
END;
$$;


/*------------------------------------------------------------------------------
  SECTION 4: Grant procedure (the Accept button calls this)
  Arguments:
    p_target_type  'USER' or 'ROLE'
    p_target_name  the user name or role name (stored uppercase; see note)
    p_limit        -1 (unlimited) or a positive number of credits per 24h
    p_approved_by  the manager who clicked Accept (recorded in the log)
    p_reason       optional free text, such as a ticket number
    p_days         optional; how long the exception lasts (default 30, max 90)

  Validation done before anything changes:
    - target type is USER or ROLE
    - name contains only letters, digits and _ $ . @ -  (blocks SQL injection;
      widen the pattern if your names use other characters)
    - limit is -1 or greater than 0 (0 would block, which isn't an exception)
    - days is between 1 and 90
    - the user exists / the role resolves to at least one user
    - PUBLIC is refused, and a role covering more than 500 users is refused

  NOTE on names: names are uppercased, which matches how Snowflake stores
  unquoted identifiers. If you have users or roles created with quoted,
  mixed-case names, remove the UPPER() below and have the UI send the exact name.
------------------------------------------------------------------------------*/
CREATE OR REPLACE PROCEDURE admin_db.util.coco_grant_limit_exception(
    p_target_type STRING,
    p_target_name STRING,
    p_limit       NUMBER,
    p_approved_by STRING,
    p_reason      STRING DEFAULT NULL,
    p_days        NUMBER DEFAULT 30
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  v_type       STRING;
  v_name       STRING;
  v_request_id STRING;
  v_now        TIMESTAMP_LTZ;
  v_expires    TIMESTAMP_LTZ;
  users        ARRAY DEFAULT ARRAY_CONSTRUCT();
  to_visit     ARRAY DEFAULT ARRAY_CONSTRUCT();
  visited      ARRAY DEFAULT ARRAY_CONSTRUCT();
  new_users    ARRAY;
  new_roles    ARRAY;
  r            STRING;
  u            STRING;
BEGIN
  v_type := UPPER(TRIM(p_target_type));
  v_name := UPPER(TRIM(p_target_name));

  -- ---------- Validate inputs ----------
  IF (v_type IS NULL OR v_type NOT IN ('USER', 'ROLE')) THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'target_type must be USER or ROLE');
  END IF;
  IF (v_name IS NULL OR NOT REGEXP_LIKE(v_name, '^[A-Z0-9_$.@-]+$')) THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Invalid user/role name: ' || COALESCE(p_target_name, 'NULL'));
  END IF;
  IF (p_limit IS NULL OR p_limit < -1 OR p_limit = 0) THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'limit must be -1 (unlimited) or greater than 0');
  END IF;
  IF (p_days IS NULL OR p_days < 1 OR p_days > 90) THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'days must be between 1 and 90');
  END IF;
  IF (p_approved_by IS NULL OR TRIM(p_approved_by) = '') THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'approved_by is required');
  END IF;
  IF (v_type = 'ROLE' AND v_name = 'PUBLIC') THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'PUBLIC cannot be given an exception; change the account-level limit instead');
  END IF;

  -- ---------- Resolve the users to change ----------
  IF (v_type = 'USER') THEN
    -- SHOW USERS LIKE treats _ as a wildcard, so filter to the exact name
    EXECUTE IMMEDIATE 'SHOW USERS LIKE ''' || v_name || '''';
    SELECT ARRAY_AGG("name") INTO :users
      FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
     WHERE "name" = :v_name;
  ELSE
    -- Walk the role hierarchy upward: users granted this role directly, plus
    -- users granted any role that has this role granted to it
    -- (they inherit it). visited prevents loops.
    to_visit := ARRAY_CONSTRUCT(v_name);
    WHILE (ARRAY_SIZE(to_visit) > 0) DO
      r := to_visit[0]::STRING;
      to_visit := ARRAY_REMOVE_AT(to_visit, 0);
      IF (ARRAY_CONTAINS(r::VARIANT, visited)) THEN
        CONTINUE;
      END IF;
      visited := ARRAY_APPEND(visited, r);

      EXECUTE IMMEDIATE 'SHOW GRANTS OF ROLE "' || REPLACE(r, '"', '""') || '"';
      SELECT ARRAY_AGG(IFF("granted_to" = 'USER', "grantee_name", NULL)),
             ARRAY_AGG(IFF("granted_to" = 'ROLE', "grantee_name", NULL))
        INTO :new_users, :new_roles
        FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

      users    := ARRAY_CAT(users, new_users);
      to_visit := ARRAY_CAT(to_visit, new_roles);
    END WHILE;
    users := ARRAY_DISTINCT(users);
  END IF;

  IF (users IS NULL OR ARRAY_SIZE(users) = 0) THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message',
           'No users found for ' || v_type || ' ' || v_name);
  END IF;
  IF (ARRAY_SIZE(users) > 500) THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message',
           'Role resolves to ' || ARRAY_SIZE(users) || ' users (limit 500); request a narrower role');
  END IF;

  -- ---------- Log and apply ----------
  v_request_id := UUID_STRING();
  v_now        := CURRENT_TIMESTAMP();
  v_expires    := DATEADD('day', p_days, v_now);

  FOR i IN 0 TO ARRAY_SIZE(users) - 1 DO
    u := users[i]::STRING;

    INSERT INTO admin_db.util.coco_limit_exception_log
      (request_id, target_type, target_name, user_name, limit_value,
       approved_by, reason, granted_at, expires_at, status)
    VALUES
      (:v_request_id, :v_type, :v_name, :u, :p_limit,
       :p_approved_by, :p_reason, :v_now, :v_expires, 'ACTIVE');

    CALL admin_db.util.coco_apply_effective_limit(:u);
  END FOR;

  RETURN OBJECT_CONSTRUCT(
           'status',      'OK',
           'request_id',  v_request_id,
           'target_type', v_type,
           'target_name', v_name,
           'users',       users,
           'limit',       p_limit,
           'expires_at',  TO_VARCHAR(v_expires, 'YYYY-MM-DD HH24:MI:SS TZH:TZM'));

EXCEPTION
  WHEN OTHER THEN
    -- Typical causes: role doesn't exist, or the owner role lacks privileges.
    -- If this fires after some users were changed, the log shows which ones;
    -- revoke the request_id or let it expire.
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM,
                            'sqlstate', SQLSTATE, 'request_id', v_request_id);
END;
$$;


/*------------------------------------------------------------------------------
  SECTION 5: Revoke procedure (optional early end)
  Ends every ACTIVE row of one request, then recalculates each affected user.
  A user who still has another active exception keeps that one.
------------------------------------------------------------------------------*/
CREATE OR REPLACE PROCEDURE admin_db.util.coco_revoke_limit_exception(
    p_request_id STRING,
    p_revoked_by STRING
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  v_now TIMESTAMP_LTZ;
  n     NUMBER DEFAULT 0;
BEGIN
  IF (p_revoked_by IS NULL OR TRIM(p_revoked_by) = '') THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'revoked_by is required');
  END IF;

  v_now := CURRENT_TIMESTAMP();

  -- Capture affected users before changing status
  LET rs RESULTSET := (
    SELECT DISTINCT user_name
      FROM admin_db.util.coco_limit_exception_log
     WHERE request_id = :p_request_id
       AND status = 'ACTIVE');

  UPDATE admin_db.util.coco_limit_exception_log
     SET status = 'REVOKED', ended_at = :v_now, ended_by = :p_revoked_by
   WHERE request_id = :p_request_id
     AND status = 'ACTIVE';

  LET c CURSOR FOR rs;
  FOR rec IN c DO
    LET u STRING := rec.user_name;
    CALL admin_db.util.coco_apply_effective_limit(:u);
    n := n + 1;
  END FOR;

  IF (n = 0) THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message',
           'No active exception found for request_id ' || COALESCE(p_request_id, 'NULL'));
  END IF;
  RETURN OBJECT_CONSTRUCT('status', 'OK', 'request_id', p_request_id, 'users_recalculated', n);

EXCEPTION
  WHEN OTHER THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'sqlstate', SQLSTATE);
END;
$$;


/*------------------------------------------------------------------------------
  SECTION 6: Expiry procedure + hourly task
  Marks ACTIVE rows past expires_at as EXPIRED, then recalculates each of
  those users. The helper also ignores expired rows on its own, so a delayed
  task run never extends an exception when another request is applied.
------------------------------------------------------------------------------*/
CREATE OR REPLACE PROCEDURE admin_db.util.coco_expire_limit_exceptions()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  v_now TIMESTAMP_LTZ;
  n     NUMBER DEFAULT 0;
BEGIN
  v_now := CURRENT_TIMESTAMP();   -- one cutoff for both statements below

  LET rs RESULTSET := (
    SELECT DISTINCT user_name
      FROM admin_db.util.coco_limit_exception_log
     WHERE status = 'ACTIVE'
       AND expires_at <= :v_now);

  UPDATE admin_db.util.coco_limit_exception_log
     SET status = 'EXPIRED', ended_at = :v_now, ended_by = 'EXPIRY_TASK'
   WHERE status = 'ACTIVE'
     AND expires_at <= :v_now;

  LET c CURSOR FOR rs;
  FOR rec IN c DO
    LET u STRING := rec.user_name;
    CALL admin_db.util.coco_apply_effective_limit(:u);
    n := n + 1;
  END FOR;

  RETURN n || ' user(s) recalculated after expiry';
END;
$$;

CREATE OR REPLACE TASK admin_db.util.coco_expire_limit_exceptions_task
  WAREHOUSE = admin_wh
  SCHEDULE  = 'USING CRON 5 * * * * America/Chicago'   -- 5 past every hour
  COMMENT   = 'Ends CoCo credit limit exceptions past their expiry date'
AS
  CALL admin_db.util.coco_expire_limit_exceptions();

ALTER TASK admin_db.util.coco_expire_limit_exceptions_task RESUME;


/*------------------------------------------------------------------------------
  SECTION 7: View for the UI
  Current exceptions, one row per user, with days remaining.
------------------------------------------------------------------------------*/
CREATE OR REPLACE VIEW admin_db.util.coco_limit_exceptions_active AS
SELECT request_id,
       target_type,
       target_name,
       user_name,
       limit_value,
       approved_by,
       reason,
       granted_at,
       expires_at,
       DATEDIFF('day', CURRENT_TIMESTAMP(), expires_at) AS days_remaining
  FROM admin_db.util.coco_limit_exception_log
 WHERE status = 'ACTIVE'
   AND expires_at > CURRENT_TIMESTAMP();


/*------------------------------------------------------------------------------
  SECTION 8: Grants for the UI role
  The UI role can call grant/revoke and read the view. It can't call the
  helper or the expiry procedure, and it can't change users directly.
  Procedure signatures list every argument type, including the defaulted ones.
------------------------------------------------------------------------------*/
GRANT USAGE ON DATABASE admin_db      TO ROLE COCO_EXCEPTION_UI;
GRANT USAGE ON SCHEMA   admin_db.util TO ROLE COCO_EXCEPTION_UI;

GRANT USAGE ON PROCEDURE admin_db.util.coco_grant_limit_exception(STRING, STRING, NUMBER, STRING, STRING, NUMBER)
  TO ROLE COCO_EXCEPTION_UI;
GRANT USAGE ON PROCEDURE admin_db.util.coco_revoke_limit_exception(STRING, STRING)
  TO ROLE COCO_EXCEPTION_UI;

GRANT SELECT ON VIEW admin_db.util.coco_limit_exceptions_active TO ROLE COCO_EXCEPTION_UI;
-- Optional, for an audit/history screen:
-- GRANT SELECT ON TABLE admin_db.util.coco_limit_exception_log TO ROLE COCO_EXCEPTION_UI;


/*------------------------------------------------------------------------------
  SECTION 9: Example calls (what the UI button sends)
------------------------------------------------------------------------------*/
-- One user, 50 credits/day, default 30 days
CALL admin_db.util.coco_grant_limit_exception('USER', 'JSMITH', 50, 'manager.name@company.com', 'TICKET-1234');

-- A role, unlimited, 14 days
CALL admin_db.util.coco_grant_limit_exception('ROLE', 'DATA_ENGINEER', -1, 'manager.name@company.com', 'Q4 migration sprint', 14);

-- Revoke early (request_id comes from the grant result or the view)
-- CALL admin_db.util.coco_revoke_limit_exception('<request_id>', 'manager.name@company.com');


/*------------------------------------------------------------------------------
  SECTION 10: Testing checklist (run in non-prod)
------------------------------------------------------------------------------*/
-- 1. Grant to a test user, then confirm LEVEL = USER and VALUE = 50:
--    SHOW PARAMETERS LIKE 'CORTEX_CODE%DAILY_EST_CREDIT_LIMIT_PER_USER' IN USER TEST_USER;
--
-- 2. Test expiry without waiting 30 days: backdate the row, then run expiry:
--    UPDATE admin_db.util.coco_limit_exception_log
--       SET expires_at = DATEADD('minute', -1, CURRENT_TIMESTAMP())
--     WHERE user_name = 'TEST_USER' AND status = 'ACTIVE';
--    CALL admin_db.util.coco_expire_limit_exceptions();
--    -> SHOW PARAMETERS ... IN USER TEST_USER should now show LEVEL blank (account default)
--
-- 3. Overlap: grant USER TEST_USER 50, then ROLE (containing TEST_USER) -1.
--    Effective = -1. Revoke the ROLE request -> TEST_USER goes back to 50.
--
-- 4. Bad input: CALL with 'GROUP', a name with a quote, limit 0, days 365.
--    Each should return status ERROR and change nothing.
--
-- 5. Nested role: grant role A to role B, user X has role B only.
--    A ROLE request for A should include X.
--
-- 6. Task history:
--    SELECT name, state, scheduled_time, return_value, error_message
--    FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
--           TASK_NAME => 'COCO_EXPIRE_LIMIT_EXCEPTIONS_TASK',
--           SCHEDULED_TIME_RANGE_START => DATEADD('day', -1, CURRENT_TIMESTAMP())))
--    ORDER BY scheduled_time DESC;


/*------------------------------------------------------------------------------
  SECTION 11: Rollback
  Ends all exceptions, resets the users, and removes the objects.
------------------------------------------------------------------------------*/
-- ALTER TASK admin_db.util.coco_expire_limit_exceptions_task SUSPEND;
--
-- UPDATE admin_db.util.coco_limit_exception_log
--    SET status = 'REVOKED', ended_at = CURRENT_TIMESTAMP(), ended_by = 'ROLLBACK'
--  WHERE status = 'ACTIVE';
--
-- EXECUTE IMMEDIATE $$
-- DECLARE
--   c CURSOR FOR SELECT DISTINCT user_name FROM admin_db.util.coco_limit_exception_log;
-- BEGIN
--   FOR rec IN c DO
--     LET u STRING := rec.user_name;
--     CALL admin_db.util.coco_apply_effective_limit(:u);   -- no active rows -> UNSET
--   END FOR;
--   RETURN 'all users reset';
-- END;
-- $$;
--
-- DROP TASK      admin_db.util.coco_expire_limit_exceptions_task;
-- DROP VIEW      admin_db.util.coco_limit_exceptions_active;
-- DROP PROCEDURE admin_db.util.coco_grant_limit_exception(STRING, STRING, NUMBER, STRING, STRING, NUMBER);
-- DROP PROCEDURE admin_db.util.coco_revoke_limit_exception(STRING, STRING);
-- DROP PROCEDURE admin_db.util.coco_expire_limit_exceptions();
-- DROP PROCEDURE admin_db.util.coco_apply_effective_limit(STRING);
-- -- Keep the log table if you need the audit trail:
-- -- DROP TABLE admin_db.util.coco_limit_exception_log;
