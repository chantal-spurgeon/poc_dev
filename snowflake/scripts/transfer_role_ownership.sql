/* =============================================================================
   TRANSFER ALL OWNERSHIP FROM ONE ROLE TO ANOTHER BEFORE DROPPING IT
   -----------------------------------------------------------------------------
   Why: DROP ROLE hands everything the dropped role owned to the role that runs
   the DROP (often SYSADMIN/SECURITYADMIN). This moves it to a role you choose
   first, so the DROP has nothing left to reassign.

   What it covers:
     - Every object the role currently OWNS (SHOW GRANTS TO ROLE ... OWNERSHIP),
       including databases, schemas, tables, views, functions/procedures,
       stages, tasks, pipes, streams, warehouses, integrations, roles, users...
     - FUTURE ownership grants held by the role (SHOW FUTURE GRANTS TO ROLE)
   Existing grants on each object to other roles are kept (COPY CURRENT GRANTS).

   Placeholders to replace:  <ADMIN_DB>.<UTIL_SCHEMA>, OLD_ROLE_NAME, NEW_ROLE_NAME
   ========================================================================== */


/* -----------------------------------------------------------------------------
   0. PREREQUISITES
   Run as a role that has MANAGE GRANTS (SECURITYADMIN). Also grant it the old
   role for now, so it can suspend that role's tasks and pause its pipes.
   -------------------------------------------------------------------------- */
USE ROLE SECURITYADMIN;

-- Create the management role if needed, and keep it under SYSADMIN in the hierarchy
CREATE ROLE IF NOT EXISTS NEW_ROLE_NAME COMMENT = 'Management role; inherits objects from OLD_ROLE_NAME';
GRANT ROLE NEW_ROLE_NAME TO ROLE SYSADMIN;

-- Temporary: let the executing role operate the old role's tasks/pipes
GRANT ROLE OLD_ROLE_NAME TO ROLE SECURITYADMIN;

-- Record task/pipe state now so you know which ones to resume afterwards
SHOW TASKS IN ACCOUNT;
SELECT "database_name", "schema_name", "name", "owner", "state"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "owner" = 'OLD_ROLE_NAME';

SHOW PIPES IN ACCOUNT;
SELECT "database_name", "schema_name", "name", "owner"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "owner" = 'OLD_ROLE_NAME';


/* -----------------------------------------------------------------------------
   1. THE PROCEDURE (caller's rights, so it runs with your current role)
   Role names: pass them unquoted for normal UPPERCASE roles ('my_role' is
   treated as MY_ROLE), or with double quotes for case-sensitive names
   ('"MixedCase"').
   -------------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE <ADMIN_DB>.<UTIL_SCHEMA>.TRANSFER_ROLE_OWNERSHIP(
    OLD_ROLE VARCHAR,
    NEW_ROLE VARCHAR,
    DRY_RUN  BOOLEAN DEFAULT TRUE
)
RETURNS TABLE (
    SEQ         NUMBER,
    OBJECT_TYPE VARCHAR,
    OBJECT_NAME VARCHAR,
    PRE_STMT    VARCHAR,
    STMT        VARCHAR,
    FOLLOW_UP   VARCHAR,
    STATUS      VARCHAR,
    MESSAGE     VARCHAR
)
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    old_q    VARCHAR;
    new_q    VARCHAR;
    sql_txt  VARCHAR;
    cur_seq  NUMBER;
    cur_pre  VARCHAR;
    cur_stmt VARCHAR;
    err_msg  VARCHAR;
    res      RESULTSET;
BEGIN
    old_q := IFF(LEFT(OLD_ROLE, 1) = '"', OLD_ROLE, '"' || UPPER(OLD_ROLE) || '"');
    new_q := IFF(LEFT(NEW_ROLE, 1) = '"', NEW_ROLE, '"' || UPPER(NEW_ROLE) || '"');

    CREATE OR REPLACE TEMPORARY TABLE OWNERSHIP_XFER_PLAN (
        SEQ         NUMBER AUTOINCREMENT,
        OBJECT_TYPE VARCHAR,
        OBJECT_NAME VARCHAR,
        PRE_STMT    VARCHAR,
        STMT        VARCHAR,
        FOLLOW_UP   VARCHAR,
        STATUS      VARCHAR,
        MESSAGE     VARCHAR
    );

    /* ---- 1a. Objects currently owned by the old role ---------------------- */
    sql_txt := 'SHOW GRANTS TO ROLE ' || old_q;
    EXECUTE IMMEDIATE :sql_txt;

    INSERT INTO OWNERSHIP_XFER_PLAN (OBJECT_TYPE, OBJECT_NAME, PRE_STMT, STMT, FOLLOW_UP, STATUS)
    WITH g AS (
        SELECT REPLACE("granted_on", '_', ' ') AS obj_type,
               "name"                         AS raw_name
        FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
        WHERE "privilege" = 'OWNERSHIP'
    ),
    -- Functions/procedures show up as DB.SCH."FN(ARG TYPE, ...):RETURN_TYPE".
    -- GRANT needs DB.SCH."FN"(TYPE, ...), so remove argument names, precision and return type.
    f AS (
        SELECT obj_type, raw_name,
               REGEXP_SUBSTR(raw_name, '"([^"]*)"$', 1, 1, 'e', 1) AS seg
        FROM g
    ),
    n AS (
        SELECT obj_type,
               CASE
                 WHEN obj_type IN ('FUNCTION', 'PROCEDURE') AND seg IS NOT NULL THEN
                      LEFT(raw_name, LENGTH(raw_name) - LENGTH(seg) - 3)          -- DB.SCH
                      || '."' || SPLIT_PART(seg, '(', 1) || '"('                  -- ."FN"(
                      || REGEXP_REPLACE(
                           REGEXP_REPLACE(
                             SUBSTR(seg, POSITION('(', seg) + 1,
                                    POSITION('):', seg) - POSITION('(', seg) - 1),
                             '(^|, *)[^ ,]+ ', '\\1'),                            -- drop arg names
                           '\\([0-9, ]*\\)', '')                                  -- drop precision
                      || ')'
                 WHEN obj_type IN ('FUNCTION', 'PROCEDURE') THEN NULL             -- unexpected format
                 WHEN CONTAINS(raw_name, '.') THEN raw_name                       -- already qualified/quoted
                 ELSE '"' || REPLACE(raw_name, '"', '""') || '"'                  -- account-level object
               END AS obj_name
        FROM f
    )
    SELECT obj_type,
           obj_name,
           CASE obj_type
             WHEN 'PIPE' THEN 'ALTER PIPE ' || obj_name || ' SET PIPE_EXECUTION_PAUSED = TRUE'
             WHEN 'TASK' THEN 'ALTER TASK ' || obj_name || ' SUSPEND'
           END,
           'GRANT OWNERSHIP ON ' || obj_type || ' ' || obj_name || ' TO ROLE ' || :new_q
             || IFF(obj_type IN ('ROLE', 'USER'), '', ' COPY CURRENT GRANTS'),
           CASE obj_type
             WHEN 'PIPE' THEN 'As ' || :new_q || ': ALTER PIPE ' || obj_name || ' SET PIPE_EXECUTION_PAUSED = FALSE'
             WHEN 'TASK' THEN 'If it was started before: ALTER TASK ' || obj_name || ' RESUME (resume children before the root)'
           END,
           IFF(obj_name IS NULL, 'NEEDS_REVIEW', 'PLANNED')
    FROM n
    ORDER BY obj_type, obj_name;

    /* ---- 1b. Future ownership grants held by the old role ----------------- */
    sql_txt := 'SHOW FUTURE GRANTS TO ROLE ' || old_q;
    EXECUTE IMMEDIATE :sql_txt;

    INSERT INTO OWNERSHIP_XFER_PLAN (OBJECT_TYPE, OBJECT_NAME, PRE_STMT, STMT, STATUS)
    WITH fg AS (
        SELECT REPLACE("grant_on", '_', ' ') || 'S'              AS plural_type,   -- TABLE -> TABLES
               REGEXP_REPLACE("name", '\\.<[^>]+>$', '')          AS container       -- DB or DB.SCH
        FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
        WHERE "privilege" = 'OWNERSHIP'
    )
    SELECT 'FUTURE ' || plural_type,
           container,
           'REVOKE OWNERSHIP ON FUTURE ' || plural_type || ' IN '
             || IFF(REGEXP_COUNT(container, '\\.') = 0, 'DATABASE ', 'SCHEMA ')
             || container || ' FROM ROLE ' || :old_q,
           'GRANT OWNERSHIP ON FUTURE ' || plural_type || ' IN '
             || IFF(REGEXP_COUNT(container, '\\.') = 0, 'DATABASE ', 'SCHEMA ')
             || container || ' TO ROLE ' || :new_q,
           'PLANNED'
    FROM fg;

    /* ---- 2. Execute (only when DRY_RUN = FALSE) --------------------------- */
    IF (NOT DRY_RUN) THEN
        LET c1 CURSOR FOR
            SELECT SEQ, PRE_STMT, STMT FROM OWNERSHIP_XFER_PLAN
            WHERE STATUS = 'PLANNED' ORDER BY SEQ;
        FOR r IN c1 DO
            cur_seq  := r.SEQ;
            cur_pre  := r.PRE_STMT;
            cur_stmt := r.STMT;
            BEGIN
                IF (cur_pre IS NOT NULL) THEN
                    EXECUTE IMMEDIATE :cur_pre;
                END IF;
                EXECUTE IMMEDIATE :cur_stmt;
                UPDATE OWNERSHIP_XFER_PLAN SET STATUS = 'DONE' WHERE SEQ = :cur_seq;
            EXCEPTION
                WHEN OTHER THEN
                    err_msg := SQLERRM;
                    UPDATE OWNERSHIP_XFER_PLAN
                       SET STATUS = 'ERROR', MESSAGE = :err_msg
                     WHERE SEQ = :cur_seq;
            END;
        END FOR;
    END IF;

    res := (SELECT SEQ, OBJECT_TYPE, OBJECT_NAME, PRE_STMT, STMT, FOLLOW_UP, STATUS, MESSAGE
            FROM OWNERSHIP_XFER_PLAN ORDER BY SEQ);
    RETURN TABLE(res);
END;
$$;


/* -----------------------------------------------------------------------------
   2. DRY RUN: review every generated statement. Nothing is changed.
      Check NEEDS_REVIEW rows and any function/procedure signatures.
   -------------------------------------------------------------------------- */
CALL <ADMIN_DB>.<UTIL_SCHEMA>.TRANSFER_ROLE_OWNERSHIP('OLD_ROLE_NAME', 'NEW_ROLE_NAME', TRUE);


/* -----------------------------------------------------------------------------
   3. EXECUTE, then look at errors
   -------------------------------------------------------------------------- */
CALL <ADMIN_DB>.<UTIL_SCHEMA>.TRANSFER_ROLE_OWNERSHIP('OLD_ROLE_NAME', 'NEW_ROLE_NAME', FALSE);

SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "STATUS" <> 'DONE';                          -- ERROR / NEEDS_REVIEW rows to handle by hand

SELECT "OBJECT_NAME", "FOLLOW_UP"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID(-2)))
WHERE "FOLLOW_UP" IS NOT NULL;                     -- tasks/pipes to resume as NEW_ROLE_NAME


/* -----------------------------------------------------------------------------
   4. (Optional) Give NEW_ROLE to the same users/roles that held OLD_ROLE
   -------------------------------------------------------------------------- */
SHOW GRANTS OF ROLE OLD_ROLE_NAME;
SELECT 'GRANT ROLE NEW_ROLE_NAME TO ' || "granted_to" || ' "' || "grantee_name" || '";' AS stmt
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "grantee_name" <> 'SECURITYADMIN';          -- skip the temporary grant from step 0
-- Also check for users with DEFAULT_ROLE = OLD_ROLE_NAME (SHOW USERS) and repoint them.


/* -----------------------------------------------------------------------------
   5. VERIFY nothing is left, then DROP
   -------------------------------------------------------------------------- */
SHOW GRANTS TO ROLE OLD_ROLE_NAME;
SELECT COUNT(*) AS remaining_ownerships
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "privilege" = 'OWNERSHIP';                   -- expect 0

SHOW FUTURE GRANTS TO ROLE OLD_ROLE_NAME;
SELECT COUNT(*) AS remaining_future_ownerships
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "privilege" = 'OWNERSHIP';                   -- expect 0

REVOKE ROLE OLD_ROLE_NAME FROM ROLE SECURITYADMIN; -- undo the temporary grant
DROP ROLE OLD_ROLE_NAME;
