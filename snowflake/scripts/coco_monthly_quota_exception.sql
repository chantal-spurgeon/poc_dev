/*=============================================================================
  CoCo MONTHLY QUOTA EXCEPTION MODULE
  -----------------------------------------------------------------------------
  Purpose : Temporarily raise a user's CoCo monthly credit quota by granting
            AI_DATA_SCIENCE (the higher budget tier in ai_role_budgets),
            log the exception, and auto-revoke it when it expires.

  Objects :
    ai_cost_mgmt.public.coco_quota_exception_seq      (sequence)
    ai_cost_mgmt.public.coco_quota_exception_log      (log table)
    ai_cost_mgmt.public.grant_coco_quota_exception    (proc: ticket Accept button)
    ai_cost_mgmt.public.close_coco_quota_exception    (proc: early revoke / make permanent)
    ai_cost_mgmt.public.expire_coco_quota_exceptions  (proc: auto-revoke expired rows)
    ai_cost_mgmt.public.expire_coco_quota_exceptions_task (hourly task)
    ai_cost_mgmt.public.v_coco_quota_exceptions_active    (view for ticket UI)

  Deploy  : Run as the SAME owner role used for the daily-limit exception
            procs. That role needs OWNERSHIP of AI_DATA_SCIENCE or MANAGE
            GRANTS (to grant/revoke it), visibility of all users for SHOW
            USERS / SHOW GRANTS TO USER, and EXECUTE TASK for the task.

  Default expiry : start of next calendar month (the quota reset), because
            quotas are calendar-month. Pass p_duration_days (1-31) to override.
=============================================================================*/

USE SCHEMA ai_cost_mgmt.public;

-------------------------------------------------------------------------------
-- 1. Log table
-------------------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS coco_quota_exception_seq;

CREATE TABLE IF NOT EXISTS coco_quota_exception_log (
    exception_id    NUMBER        DEFAULT coco_quota_exception_seq.NEXTVAL,
    ticket_id       VARCHAR,
    user_name       VARCHAR       NOT NULL,
    granted_role    VARCHAR       NOT NULL,
    approved_by     VARCHAR,
    executed_by     VARCHAR,      -- CURRENT_USER() at call time
    reason          VARCHAR,
    granted_at      TIMESTAMP_LTZ,
    expires_at      TIMESTAMP_LTZ,
    status          VARCHAR,      -- ACTIVE | EXPIRED | REVOKED_EARLY | MADE_PERMANENT | SKIPPED | FAILED
    closed_at       TIMESTAMP_LTZ,
    closed_by       VARCHAR,
    notes           VARCHAR,
    CONSTRAINT pk_coco_quota_exception PRIMARY KEY (exception_id)
);

-------------------------------------------------------------------------------
-- 2. Grant procedure (called by the ticket system's Accept button)
--    Returns a VARIANT so the UI can display/record the outcome.
--
--    Outcomes:
--      GRANTED      - role granted, exception logged
--      EXTENDED     - user already had an active exception; expiry pushed out
--      ALREADY_ACTIVE - active exception already covers the requested expiry
--      NOT_NEEDED   - user already holds AI_DATA_SCIENCE permanently
--      REJECTED     - validation failed (unknown/disabled user, bad duration)
--      ERROR        - unexpected failure (logged as FAILED)
-------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE grant_coco_quota_exception(
    p_user_name     VARCHAR,
    p_ticket_id     VARCHAR,
    p_approved_by   VARCHAR,
    p_reason        VARCHAR DEFAULT NULL,
    p_duration_days NUMBER  DEFAULT NULL
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    c_role          VARCHAR DEFAULT 'AI_DATA_SCIENCE';
    v_user          VARCHAR;
    v_user_q        VARCHAR;
    v_disabled      VARCHAR;
    v_cnt           NUMBER;
    v_expires_at    TIMESTAMP_LTZ;
    v_existing_id   NUMBER;
    v_existing_exp  TIMESTAMP_LTZ;
    v_new_id        NUMBER;
BEGIN
    ---------------------------------------------------------------- validate
    IF (p_user_name IS NULL OR TRIM(p_user_name) = '') THEN
        RETURN OBJECT_CONSTRUCT('status','REJECTED','message','p_user_name is required');
    END IF;

    IF (p_duration_days IS NOT NULL AND (p_duration_days < 1 OR p_duration_days > 31)) THEN
        RETURN OBJECT_CONSTRUCT('status','REJECTED','message','p_duration_days must be between 1 and 31');
    END IF;

    -- Target role must have a budget row, otherwise the grant raises nothing
    SELECT COUNT(*) INTO :v_cnt
      FROM ai_cost_mgmt.public.ai_role_budgets
     WHERE UPPER(role_name) = :c_role;
    IF (v_cnt = 0) THEN
        RETURN OBJECT_CONSTRUCT('status','REJECTED',
               'message', c_role || ' has no row in ai_role_budgets');
    END IF;

    -- Resolve exact user name (LIKE treats _ as a wildcard, so re-filter exactly)
    EXECUTE IMMEDIATE 'SHOW USERS LIKE ''' || REPLACE(TRIM(p_user_name), '''', '''''') || '''';
    SELECT COUNT(*), MAX("name"), MAX("disabled")
      INTO :v_cnt, :v_user, :v_disabled
      FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
     WHERE UPPER("name") = UPPER(TRIM(:p_user_name));

    IF (v_cnt = 0) THEN
        RETURN OBJECT_CONSTRUCT('status','REJECTED','message','User not found: ' || p_user_name);
    END IF;
    IF (LOWER(v_disabled) = 'true') THEN
        RETURN OBJECT_CONSTRUCT('status','REJECTED','message','User is disabled: ' || v_user);
    END IF;

    v_user_q := '"' || REPLACE(v_user, '"', '""') || '"';

    v_expires_at := CASE
        WHEN p_duration_days IS NULL
            THEN DATEADD(month, 1, DATE_TRUNC('month', CURRENT_TIMESTAMP()))
        ELSE DATEADD(day, p_duration_days, CURRENT_TIMESTAMP())
    END;

    ---------------------------------------- existing active exception? extend
    SELECT MAX(exception_id), MAX(expires_at)
      INTO :v_existing_id, :v_existing_exp
      FROM coco_quota_exception_log
     WHERE user_name = :v_user
       AND granted_role = :c_role
       AND status = 'ACTIVE';

    IF (v_existing_id IS NOT NULL) THEN
        IF (v_expires_at > v_existing_exp) THEN
            UPDATE coco_quota_exception_log
               SET expires_at = :v_expires_at,
                   notes = COALESCE(notes || ' | ', '')
                           || 'Extended by ticket ' || COALESCE(:p_ticket_id, '?')
                           || ' approved by ' || COALESCE(:p_approved_by, '?')
                           || ' on ' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYY-MM-DD HH24:MI TZH:TZM')
             WHERE exception_id = :v_existing_id;
            RETURN OBJECT_CONSTRUCT('status','EXTENDED','exception_id', v_existing_id,
                                    'user_name', v_user, 'expires_at', v_expires_at);
        END IF;
        RETURN OBJECT_CONSTRUCT('status','ALREADY_ACTIVE','exception_id', v_existing_id,
                                'user_name', v_user, 'expires_at', v_existing_exp);
    END IF;

    ------------------------------------- user already holds the role directly?
    EXECUTE IMMEDIATE 'SHOW GRANTS TO USER ' || v_user_q;
    SELECT COUNT(*) INTO :v_cnt
      FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
     WHERE "role" = :c_role;

    IF (v_cnt > 0) THEN
        INSERT INTO coco_quota_exception_log
            (ticket_id, user_name, granted_role, approved_by, executed_by, reason,
             status, closed_at, closed_by, notes)
        VALUES
            (:p_ticket_id, :v_user, :c_role, :p_approved_by, CURRENT_USER(), :p_reason,
             'SKIPPED', CURRENT_TIMESTAMP(), 'SYSTEM',
             'User already holds ' || :c_role || ' outside of an exception; nothing granted');
        RETURN OBJECT_CONSTRUCT('status','NOT_NEEDED','user_name', v_user,
               'message', 'User already holds ' || c_role);
    END IF;

    ---------------------------------------------------------------- grant
    EXECUTE IMMEDIATE 'GRANT ROLE "' || c_role || '" TO USER ' || v_user_q;

    SELECT coco_quota_exception_seq.NEXTVAL INTO :v_new_id;

    INSERT INTO coco_quota_exception_log
        (exception_id, ticket_id, user_name, granted_role, approved_by, executed_by,
         reason, granted_at, expires_at, status)
    VALUES
        (:v_new_id, :p_ticket_id, :v_user, :c_role, :p_approved_by, CURRENT_USER(),
         :p_reason, CURRENT_TIMESTAMP(), :v_expires_at, 'ACTIVE');

    RETURN OBJECT_CONSTRUCT('status','GRANTED','exception_id', v_new_id,
                            'user_name', v_user, 'granted_role', c_role,
                            'expires_at', v_expires_at);

EXCEPTION
    WHEN OTHER THEN
        INSERT INTO coco_quota_exception_log
            (ticket_id, user_name, granted_role, approved_by, executed_by, reason,
             status, closed_at, closed_by, notes)
        VALUES
            (:p_ticket_id, COALESCE(:v_user, UPPER(:p_user_name)), :c_role, :p_approved_by,
             CURRENT_USER(), :p_reason, 'FAILED', CURRENT_TIMESTAMP(), 'SYSTEM',
             'SQLCODE ' || :sqlcode || ': ' || :sqlerrm);
        RETURN OBJECT_CONSTRUCT('status','ERROR','sqlcode', sqlcode,
                                'sqlstate', sqlstate, 'message', sqlerrm);
END;
$$;

-------------------------------------------------------------------------------
-- 3. Close an exception early (manager cancels it, or the user is being
--    moved to AI_DATA_SCIENCE permanently -> p_keep_role = TRUE)
-------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE close_coco_quota_exception(
    p_exception_id  NUMBER,
    p_closed_by     VARCHAR,
    p_keep_role     BOOLEAN DEFAULT FALSE,
    p_note          VARCHAR DEFAULT NULL
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_user   VARCHAR;
    v_role   VARCHAR;
    v_status VARCHAR;
BEGIN
    SELECT MAX(user_name), MAX(granted_role), MAX(status)
      INTO :v_user, :v_role, :v_status
      FROM coco_quota_exception_log
     WHERE exception_id = :p_exception_id;

    IF (v_user IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status','REJECTED','message','exception_id not found');
    END IF;
    IF (v_status <> 'ACTIVE') THEN
        RETURN OBJECT_CONSTRUCT('status','REJECTED','message','Exception is ' || v_status || ', not ACTIVE');
    END IF;

    IF (NOT p_keep_role) THEN
        EXECUTE IMMEDIATE 'REVOKE ROLE "' || v_role || '" FROM USER "'
                          || REPLACE(v_user, '"', '""') || '"';
    END IF;

    UPDATE coco_quota_exception_log
       SET status    = IFF(:p_keep_role, 'MADE_PERMANENT', 'REVOKED_EARLY'),
           closed_at = CURRENT_TIMESTAMP(),
           closed_by = :p_closed_by,
           notes     = COALESCE(notes || ' | ', '') || COALESCE(:p_note, '')
     WHERE exception_id = :p_exception_id;

    RETURN OBJECT_CONSTRUCT('status', IFF(p_keep_role, 'MADE_PERMANENT', 'REVOKED_EARLY'),
                            'exception_id', p_exception_id, 'user_name', v_user);
EXCEPTION
    WHEN OTHER THEN
        RETURN OBJECT_CONSTRUCT('status','ERROR','sqlcode', sqlcode, 'message', sqlerrm);
END;
$$;

-------------------------------------------------------------------------------
-- 4. Expiry procedure: revoke every ACTIVE exception whose expires_at passed.
--    Each row is handled independently so one failure doesn't block the rest;
--    failed rows stay ACTIVE and are retried on the next run.
-------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE expire_coco_quota_exceptions()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    c_due CURSOR FOR
        SELECT exception_id, user_name, granted_role
          FROM ai_cost_mgmt.public.coco_quota_exception_log
         WHERE status = 'ACTIVE'
           AND expires_at <= CURRENT_TIMESTAMP();
    v_expired NUMBER DEFAULT 0;
    v_failed  ARRAY  DEFAULT ARRAY_CONSTRUCT();
BEGIN
    FOR r IN c_due DO
        LET v_id   NUMBER  := r.exception_id;
        LET v_user VARCHAR := r.user_name;
        LET v_role VARCHAR := r.granted_role;
        BEGIN
            EXECUTE IMMEDIATE 'REVOKE ROLE "' || v_role || '" FROM USER "'
                              || REPLACE(v_user, '"', '""') || '"';
            UPDATE ai_cost_mgmt.public.coco_quota_exception_log
               SET status = 'EXPIRED',
                   closed_at = CURRENT_TIMESTAMP(),
                   closed_by = 'EXPIRY_TASK'
             WHERE exception_id = :v_id;
            v_expired := v_expired + 1;
        EXCEPTION
            WHEN OTHER THEN
                UPDATE ai_cost_mgmt.public.coco_quota_exception_log
                   SET notes = COALESCE(notes || ' | ', '')
                               || 'Expiry failed ' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYY-MM-DD HH24:MI')
                               || ': ' || :sqlerrm
                 WHERE exception_id = :v_id;
                v_failed := ARRAY_APPEND(v_failed,
                            OBJECT_CONSTRUCT('exception_id', v_id, 'user_name', v_user, 'error', sqlerrm));
        END;
    END FOR;

    RETURN OBJECT_CONSTRUCT('expired', v_expired, 'failed', v_failed);
END;
$$;

-------------------------------------------------------------------------------
-- 5. Hourly expiry task (runs at :05 so it lands right after a 00:00 reset)
-------------------------------------------------------------------------------
CREATE OR REPLACE TASK expire_coco_quota_exceptions_task
    WAREHOUSE = <your_admin_wh>          -- or drop this line and use serverless:
    -- USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
    SCHEDULE  = 'USING CRON 5 * * * * America/Chicago'
    COMMENT   = 'Revokes expired CoCo monthly quota exceptions (AI_DATA_SCIENCE)'
AS
    CALL ai_cost_mgmt.public.expire_coco_quota_exceptions();

ALTER TASK expire_coco_quota_exceptions_task RESUME;

-------------------------------------------------------------------------------
-- 6. View for the ticket system / dashboard
-------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_coco_quota_exceptions_active AS
SELECT exception_id,
       ticket_id,
       user_name,
       granted_role,
       approved_by,
       reason,
       granted_at,
       expires_at,
       DATEDIFF(hour, CURRENT_TIMESTAMP(), expires_at) AS hours_remaining,
       notes
  FROM coco_quota_exception_log
 WHERE status = 'ACTIVE';

/*=============================================================================
  USAGE (from the ticket system)
-----------------------------------------------------------------------------
  -- Accept: grant until the next monthly reset
  CALL ai_cost_mgmt.public.grant_coco_quota_exception(
       'JDOE', 'INC0012345', 'MSMITH', 'Month-end model refresh');

  -- Accept: grant for a fixed 7 days instead
  CALL ai_cost_mgmt.public.grant_coco_quota_exception(
       'JDOE', 'INC0012345', 'MSMITH', 'Short project', 7);

  -- Cancel early / convert to permanent
  CALL ai_cost_mgmt.public.close_coco_quota_exception(42, 'MSMITH');
  CALL ai_cost_mgmt.public.close_coco_quota_exception(42, 'MSMITH', TRUE, 'Moved to DS team');

  -- Audit
  SELECT * FROM ai_cost_mgmt.public.v_coco_quota_exceptions_active;
  SELECT * FROM ai_cost_mgmt.public.coco_quota_exception_log ORDER BY exception_id DESC;

-----------------------------------------------------------------------------
  REQUIRED CHANGE TO THE 1ST-OF-MONTH RESET TASK
-----------------------------------------------------------------------------
  If the hourly enforcement task revokes AI_DATA_SCIENCE from a user during
  their exception (they burned through the DS budget too), the reset would
  later re-grant it, after the exception has ended, and the user would keep
  DS permanently. Add a filter like this to the reset's re-grant query
  (adjust names to your revocation log):

    AND NOT EXISTS (
        SELECT 1
          FROM ai_cost_mgmt.public.coco_quota_exception_log e
         WHERE e.user_name    = <revocation_log>.user_name
           AND e.granted_role = <revocation_log>.role_name
           AND e.status IN ('EXPIRED', 'REVOKED_EARLY')
    )
=============================================================================*/
