/*******************************************************************************
  system_view_monitoring_setup.sql

  Keeps our wrapper views from breaking when Snowflake changes the columns of
  SNOWFLAKE database views (ACCOUNT_USAGE, ORGANIZATION_USAGE, ...) or SHOW
  command output.

  Creates:
    Section 1  Schema and tables
    Section 2  Daily column snapshot + drift alert            (any account)
    Section 3  Dependency inventory (watched_system_objects)  (production)
    Section 4  Preview-bundle test                            (sandbox only;
               the procedure refuses to run in any other account)
    Section 5  Resume tasks and alert

  HOW TO RUN
  ----------
  This file is a Jinja template. Run it with EXECUTE IMMEDIATE FROM, from a
  stage or a Git repository stage, and supply the variables:

    EXECUTE IMMEDIATE FROM @admin.mon.deploy_stage/system_view_monitoring_setup.sql
      USING (
        db               => 'ADMIN',
        sch              => 'MON',
        wh               => 'ADMIN_WH',
        email_int        => 'OPS_EMAIL_INT',
        recipients       => 'dba-team@company.com',
        sandbox_account  => 'MY_SANDBOX_ACCOUNT',   -- CURRENT_ACCOUNT_NAME() of the sandbox
        tz               => 'America/Chicago'
      );

  Running it in a worksheet instead: find and replace each {{ ... }} token first.

  PRIVILEGES
  ----------
  Run as ACCOUNTADMIN, or a role with: CREATE INTEGRATION, IMPORTED PRIVILEGES
  on the SNOWFLAKE database, EXECUTE TASK, EXECUTE ALERT, and CREATE on the
  target schema. SYSTEM$ENABLE/DISABLE_BEHAVIOR_CHANGE_BUNDLE require
  ACCOUNTADMIN, so the Section 4 task must run as a role that can call them.

  Email recipients must be verified users in the account.
*******************************************************************************/


/*==============================================================================
  SECTION 1  Schema and tables
==============================================================================*/

CREATE DATABASE IF NOT EXISTS {{ db }};
CREATE SCHEMA   IF NOT EXISTS {{ db }}.{{ sch }};

CREATE NOTIFICATION INTEGRATION IF NOT EXISTS {{ email_int }}
  TYPE = EMAIL
  ENABLED = TRUE
  ALLOWED_RECIPIENTS = ('{{ recipients }}')
  COMMENT = 'System view / SHOW column change notifications';

-- Daily column snapshots (30-day retention, enforced by the procedure)
CREATE TABLE IF NOT EXISTS {{ db }}.{{ sch }}.sys_cols_snapshot (
  snap_ts          TIMESTAMP_LTZ,
  object_kind      STRING,          -- 'VIEW' | 'SHOW'
  object_name      STRING,          -- SCHEMA.VIEW, or the SHOW command text
  column_name      STRING,
  data_type        STRING,
  ordinal_position NUMBER
);

-- Our objects that depend on system views (refreshed weekly in production)
CREATE TABLE IF NOT EXISTS {{ db }}.{{ sch }}.watched_system_objects (
  system_object    STRING,          -- e.g. SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  our_object       STRING,          -- DB.SCHEMA.OBJECT
  our_object_type  STRING,          -- VIEW | FUNCTION | PROCEDURE | ...
  source           STRING,          -- 'DEPENDENCY' | 'TEXT_SCAN'
  depth            NUMBER,          -- 1 = references the system view directly
  chain            STRING,
  refreshed_at     TIMESTAMP_LTZ
);

-- Preview-bundle captures (30-day retention)
CREATE TABLE IF NOT EXISTS {{ db }}.{{ sch }}.bcr_cols_capture (
  run_id           STRING,
  bundle           STRING,
  phase            STRING,          -- 'BASELINE' | 'BUNDLE'
  captured_at      TIMESTAMP_LTZ,
  object_kind      STRING,
  object_name      STRING,
  column_name      STRING,
  data_type        STRING,
  ordinal_position NUMBER
);

-- Preview-bundle findings (kept, so a change is reported only once per bundle)
CREATE TABLE IF NOT EXISTS {{ db }}.{{ sch }}.bcr_test_findings (
  run_id      STRING,
  bundle      STRING,
  found_at    TIMESTAMP_LTZ,
  object_kind STRING,
  object_name STRING,
  column_name STRING,
  change      STRING,
  old_type    STRING,
  new_type    STRING
);


/*==============================================================================
  SECTION 2  Daily column snapshot + drift alert
==============================================================================*/

-- Shared capture logic: writes one set of rows per call into the given table.
-- Edit the SHOW command list to the commands our code actually reads.
CREATE OR REPLACE PROCEDURE {{ db }}.{{ sch }}.capture_system_columns(
    p_run_id STRING, p_bundle STRING, p_phase STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  cmds ARRAY DEFAULT ARRAY_CONSTRUCT('SHOW WAREHOUSES', 'SHOW USERS', 'SHOW ROLES',
                                     'SHOW DATABASES', 'SHOW GRANTS TO ROLE PUBLIC');
  c   STRING;
  qid STRING;
  ts  TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
BEGIN
  INSERT INTO {{ db }}.{{ sch }}.bcr_cols_capture
    SELECT :p_run_id, :p_bundle, :p_phase, :ts, 'VIEW',
           table_schema || '.' || table_name, column_name, data_type, ordinal_position
    FROM snowflake.information_schema.columns
    WHERE table_schema IN ('ACCOUNT_USAGE', 'ORGANIZATION_USAGE',
                           'DATA_SHARING_USAGE', 'READER_ACCOUNT_USAGE');

  FOR i IN 0 TO ARRAY_SIZE(cmds) - 1 DO
    c := cmds[i]::STRING;
    EXECUTE IMMEDIATE :c;
    qid := LAST_QUERY_ID();
    EXECUTE IMMEDIATE 'DESCRIBE RESULT ''' || qid || '''';
    INSERT INTO {{ db }}.{{ sch }}.bcr_cols_capture
      SELECT :p_run_id, :p_bundle, :p_phase, :ts, 'SHOW', :c, "name", "type", NULL
      FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
  END FOR;

  RETURN 'ok';
END;
$$;

-- Daily snapshot: reuses the capture procedure, then copies into sys_cols_snapshot.
CREATE OR REPLACE PROCEDURE {{ db }}.{{ sch }}.snapshot_system_columns()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  v_run_id STRING DEFAULT UUID_STRING();
BEGIN
  -- Keep 30 days of snapshots
  DELETE FROM {{ db }}.{{ sch }}.sys_cols_snapshot
    WHERE snap_ts < DATEADD(day, -30, CURRENT_TIMESTAMP());

  CALL {{ db }}.{{ sch }}.capture_system_columns(:v_run_id, 'DAILY', 'SNAPSHOT');

  INSERT INTO {{ db }}.{{ sch }}.sys_cols_snapshot
    SELECT captured_at, object_kind, object_name, column_name, data_type, ordinal_position
    FROM {{ db }}.{{ sch }}.bcr_cols_capture
    WHERE run_id = :v_run_id;

  DELETE FROM {{ db }}.{{ sch }}.bcr_cols_capture WHERE run_id = :v_run_id;

  RETURN 'ok';
END;
$$;

-- Differences between the two most recent daily snapshots
CREATE OR REPLACE VIEW {{ db }}.{{ sch }}.sys_cols_drift AS
WITH snaps AS (
  SELECT DISTINCT snap_ts
  FROM {{ db }}.{{ sch }}.sys_cols_snapshot
  QUALIFY DENSE_RANK() OVER (ORDER BY snap_ts DESC) <= 2
),
cur  AS (SELECT * FROM {{ db }}.{{ sch }}.sys_cols_snapshot
         WHERE snap_ts = (SELECT MAX(snap_ts) FROM snaps)),
prev AS (SELECT * FROM {{ db }}.{{ sch }}.sys_cols_snapshot
         WHERE snap_ts = (SELECT MIN(snap_ts) FROM snaps)
           AND (SELECT COUNT(*) FROM snaps) = 2)      -- no diff until 2 snapshots exist
SELECT COALESCE(c.object_kind, p.object_kind) AS object_kind,
       COALESCE(c.object_name, p.object_name) AS object_name,
       COALESCE(c.column_name, p.column_name) AS column_name,
       CASE WHEN p.column_name IS NULL THEN 'ADDED'
            WHEN c.column_name IS NULL THEN 'REMOVED'
            ELSE 'TYPE/POSITION CHANGED' END  AS change,
       p.data_type AS old_type,
       c.data_type AS new_type
FROM cur c
FULL OUTER JOIN prev p
  ON  c.object_kind = p.object_kind
  AND c.object_name = p.object_name
  AND c.column_name = p.column_name
WHERE (SELECT COUNT(*) FROM snaps) = 2
  AND ( p.column_name IS NULL OR c.column_name IS NULL
        OR c.data_type <> p.data_type
        OR COALESCE(c.ordinal_position, -1) <> COALESCE(p.ordinal_position, -1) );

-- Sends the drift details, with any of our objects that depend on them
CREATE OR REPLACE PROCEDURE {{ db }}.{{ sch }}.notify_sys_cols_drift()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  n    INT DEFAULT 0;
  body STRING;
BEGIN
  SELECT COUNT(*),
         LISTAGG(d.object_kind || ' | ' || d.object_name || '.' || d.column_name || ' | ' || d.change
                 || COALESCE(' (' || d.old_type || ' -> ' || d.new_type || ')', '')
                 || COALESCE('  ->  used by: ' || w.used_by, ''), '\n')
           WITHIN GROUP (ORDER BY d.object_kind, d.object_name, d.column_name)
    INTO :n, :body
  FROM {{ db }}.{{ sch }}.sys_cols_drift d
  LEFT JOIN (
    SELECT system_object, LISTAGG(DISTINCT our_object, ', ') AS used_by
    FROM {{ db }}.{{ sch }}.watched_system_objects
    GROUP BY system_object
  ) w
    ON w.system_object = 'SNOWFLAKE.' || d.object_name;

  IF (n > 0) THEN
    CALL SYSTEM$SEND_EMAIL('{{ email_int }}', '{{ recipients }}',
      'Snowflake system view / SHOW column change detected (' || CURRENT_ACCOUNT_NAME() || ')',
      :body);
  END IF;

  RETURN n || ' change(s)';
END;
$$;

CREATE OR REPLACE TASK {{ db }}.{{ sch }}.snapshot_system_columns_task
  WAREHOUSE = {{ wh }}
  SCHEDULE  = 'USING CRON 0 6 * * * {{ tz }}'
  COMMENT   = 'Daily snapshot of SNOWFLAKE view and SHOW output columns'
AS
  CALL {{ db }}.{{ sch }}.snapshot_system_columns();

CREATE OR REPLACE ALERT {{ db }}.{{ sch }}.sys_cols_drift_alert
  WAREHOUSE = {{ wh }}
  SCHEDULE  = 'USING CRON 30 6 * * * {{ tz }}'
  IF (EXISTS (SELECT 1 FROM {{ db }}.{{ sch }}.sys_cols_drift))
  THEN
    CALL {{ db }}.{{ sch }}.notify_sys_cols_drift();


/*==============================================================================
  SECTION 3  Dependency inventory (production)
  Combines OBJECT_DEPENDENCIES (incl. chains) with a scan of view, function
  and procedure definitions. OBJECT_DEPENDENCIES can lag by up to 3 hours.
==============================================================================*/

CREATE OR REPLACE PROCEDURE {{ db }}.{{ sch }}.refresh_watched_system_objects()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  ts TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
BEGIN
  DELETE FROM {{ db }}.{{ sch }}.watched_system_objects;

  -- 1. Recorded dependencies, following chains up to 10 levels
  INSERT INTO {{ db }}.{{ sch }}.watched_system_objects
  WITH RECURSIVE deps AS (
    SELECT referencing_database AS ref_db, referencing_schema AS ref_schema,
           referencing_object_name AS ref_name, referencing_object_domain AS ref_domain,
           referenced_database || '.' || referenced_schema || '.' || referenced_object_name AS system_object,
           1 AS depth,
           referencing_database || '.' || referencing_schema || '.' || referencing_object_name AS chain
    FROM snowflake.account_usage.object_dependencies
    WHERE referenced_database = 'SNOWFLAKE'
      AND referencing_database <> 'SNOWFLAKE'
    UNION ALL
    SELECT od.referencing_database, od.referencing_schema,
           od.referencing_object_name, od.referencing_object_domain,
           d.system_object, d.depth + 1,
           d.chain || ' <- ' || od.referencing_database || '.' || od.referencing_schema
                   || '.' || od.referencing_object_name
    FROM snowflake.account_usage.object_dependencies od
    JOIN deps d
      ON  od.referenced_database    = d.ref_db
      AND od.referenced_schema      = d.ref_schema
      AND od.referenced_object_name = d.ref_name
    WHERE d.depth < 10
  )
  SELECT system_object,
         ref_db || '.' || ref_schema || '.' || ref_name,
         ref_domain, 'DEPENDENCY', depth, chain, :ts
  FROM deps;

  -- 2. Text scan of definitions (catches procedures and objects not yet recorded)
  INSERT INTO {{ db }}.{{ sch }}.watched_system_objects
  WITH defs AS (
    SELECT table_catalog || '.' || table_schema || '.' || table_name AS our_object,
           'VIEW' AS our_object_type,
           UPPER(REPLACE(view_definition, '"', '')) AS def
    FROM snowflake.account_usage.views
    WHERE deleted IS NULL AND table_catalog <> 'SNOWFLAKE'
    UNION ALL
    SELECT function_catalog || '.' || function_schema || '.' || function_name, 'FUNCTION',
           UPPER(REPLACE(function_definition, '"', ''))
    FROM snowflake.account_usage.functions
    WHERE deleted IS NULL
    UNION ALL
    SELECT procedure_catalog || '.' || procedure_schema || '.' || procedure_name, 'PROCEDURE',
           UPPER(REPLACE(procedure_definition, '"', ''))
    FROM snowflake.account_usage.procedures
    WHERE deleted IS NULL
  ),
  refs AS (
    SELECT our_object, our_object_type, f.value::STRING AS ref
    FROM defs,
         LATERAL FLATTEN(INPUT => ARRAY_DISTINCT(REGEXP_SUBSTR_ALL(def,
           '(SNOWFLAKE\\.)?(ACCOUNT_USAGE|ORGANIZATION_USAGE|DATA_SHARING_USAGE|READER_ACCOUNT_USAGE)\\.[A-Z0-9_$]+'))) f
  )
  SELECT IFF(STARTSWITH(ref, 'SNOWFLAKE.'), ref, 'SNOWFLAKE.' || ref),
         our_object, our_object_type, 'TEXT_SCAN', 1, our_object, :ts
  FROM refs
  -- skip objects already found through recorded dependencies
  WHERE NOT EXISTS (
    SELECT 1 FROM {{ db }}.{{ sch }}.watched_system_objects w
    WHERE w.our_object = refs.our_object
      AND w.system_object = IFF(STARTSWITH(refs.ref, 'SNOWFLAKE.'), refs.ref, 'SNOWFLAKE.' || refs.ref)
  );

  RETURN 'ok';
END;
$$;

CREATE OR REPLACE TASK {{ db }}.{{ sch }}.refresh_watched_system_objects_task
  WAREHOUSE = {{ wh }}
  SCHEDULE  = 'USING CRON 0 5 * * 1 {{ tz }}'
  COMMENT   = 'Weekly inventory of our objects that depend on SNOWFLAKE system views'
AS
  CALL {{ db }}.{{ sch }}.refresh_watched_system_objects();


/*==============================================================================
  SECTION 4  Preview-bundle test (sandbox only)
  For each preview bundle (isDefault = false, isEnabled = false):
    capture baseline -> enable bundle -> capture -> optionally disable -> diff
  Emails only changes not already reported for that bundle.
==============================================================================*/

CREATE OR REPLACE PROCEDURE {{ db }}.{{ sch }}.test_preview_bundles(p_revert BOOLEAN)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  v_run_id  STRING DEFAULT UUID_STRING();
  b         STRING DEFAULT NULL;
  tested    INT    DEFAULT 0;
  n_changes INT    DEFAULT 0;
  body      STRING;
  cur CURSOR FOR
    SELECT f.value:name::STRING AS bundle_name
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(SYSTEM$SHOW_ACTIVE_BEHAVIOR_CHANGE_BUNDLES()))) f
    WHERE f.value:isDefault::BOOLEAN = FALSE
      AND f.value:isEnabled::BOOLEAN = FALSE;
BEGIN
  -- Safeguard: never enable bundles outside the sandbox account
  IF (CURRENT_ACCOUNT_NAME() <> UPPER('{{ sandbox_account }}')) THEN
    RETURN 'Skipped: ' || CURRENT_ACCOUNT_NAME() || ' is not the sandbox account';
  END IF;

  -- Step 1: preview bundles available?
  FOR r IN cur DO
    b := r.bundle_name;
    tested := tested + 1;

    -- Step 2: baseline -> enable -> capture
    CALL {{ db }}.{{ sch }}.capture_system_columns(:v_run_id, :b, 'BASELINE');
    SELECT SYSTEM$ENABLE_BEHAVIOR_CHANGE_BUNDLE(:b);
    CALL {{ db }}.{{ sch }}.capture_system_columns(:v_run_id, :b, 'BUNDLE');

    -- Step 3 (optional): return the account to its previous state
    IF (p_revert) THEN
      SELECT SYSTEM$DISABLE_BEHAVIOR_CHANGE_BUNDLE(:b);
    END IF;

    -- Record differences not already reported for this bundle
    INSERT INTO {{ db }}.{{ sch }}.bcr_test_findings
    WITH base AS (SELECT * FROM {{ db }}.{{ sch }}.bcr_cols_capture
                  WHERE run_id = :v_run_id AND bundle = :b AND phase = 'BASELINE'),
         bun  AS (SELECT * FROM {{ db }}.{{ sch }}.bcr_cols_capture
                  WHERE run_id = :v_run_id AND bundle = :b AND phase = 'BUNDLE'),
         d AS (
           SELECT COALESCE(n.object_kind, o.object_kind) AS object_kind,
                  COALESCE(n.object_name, o.object_name) AS object_name,
                  COALESCE(n.column_name, o.column_name) AS column_name,
                  CASE WHEN o.column_name IS NULL THEN 'ADDED'
                       WHEN n.column_name IS NULL THEN 'REMOVED'
                       ELSE 'TYPE/POSITION CHANGED' END AS change,
                  o.data_type AS old_type,
                  n.data_type AS new_type
           FROM bun n
           FULL OUTER JOIN base o
             ON  n.object_kind = o.object_kind
             AND n.object_name = o.object_name
             AND n.column_name = o.column_name
           WHERE o.column_name IS NULL OR n.column_name IS NULL
              OR n.data_type <> o.data_type
              OR COALESCE(n.ordinal_position, -1) <> COALESCE(o.ordinal_position, -1)
         )
    SELECT :v_run_id, :b, CURRENT_TIMESTAMP(),
           d.object_kind, d.object_name, d.column_name, d.change, d.old_type, d.new_type
    FROM d
    WHERE NOT EXISTS (
      SELECT 1 FROM {{ db }}.{{ sch }}.bcr_test_findings p
      WHERE p.bundle      = :b
        AND p.object_name = d.object_name
        AND p.column_name = d.column_name
        AND p.change      = d.change
    );
  END FOR;

  -- Keep 30 days of captures
  DELETE FROM {{ db }}.{{ sch }}.bcr_cols_capture
    WHERE captured_at < DATEADD(day, -30, CURRENT_TIMESTAMP());

  IF (tested = 0) THEN
    RETURN 'No preview bundles available';
  END IF;

  -- Step 4: notify on new findings only
  SELECT COUNT(*),
         LISTAGG(bundle || ' | ' || object_kind || ' | ' || object_name || '.' || column_name
                 || ' | ' || change
                 || COALESCE(' (' || old_type || ' -> ' || new_type || ')', ''), '\n')
           WITHIN GROUP (ORDER BY bundle, object_kind, object_name, column_name)
    INTO :n_changes, :body
  FROM {{ db }}.{{ sch }}.bcr_test_findings
  WHERE run_id = :v_run_id;

  IF (n_changes > 0) THEN
    CALL SYSTEM$SEND_EMAIL('{{ email_int }}', '{{ recipients }}',
      'Preview bundle changes Snowflake system view / SHOW columns', :body);
  END IF;

  RETURN tested || ' bundle(s) tested, ' || n_changes || ' new change(s)';

EXCEPTION
  WHEN OTHER THEN
    -- Never leave a bundle enabled by accident when revert was requested
    IF (p_revert AND b IS NOT NULL) THEN
      SELECT SYSTEM$DISABLE_BEHAVIOR_CHANGE_BUNDLE(:b);
    END IF;
    RAISE;
END;
$$;

-- Weekly, Monday 7am. TRUE = revert the bundle after testing (recommended).
CREATE OR REPLACE TASK {{ db }}.{{ sch }}.test_preview_bundles_task
  WAREHOUSE = {{ wh }}
  SCHEDULE  = 'USING CRON 0 7 * * 1 {{ tz }}'
  COMMENT   = 'Tests preview behavior change bundles for system view / SHOW column changes (sandbox only)'
AS
  CALL {{ db }}.{{ sch }}.test_preview_bundles(TRUE);


/*==============================================================================
  SECTION 5  Resume
  The preview-bundle procedure exits immediately outside the sandbox account,
  so resuming its task everywhere is safe. Before resuming it in the sandbox,
  run it once by hand and confirm the BUNDLE capture shows the new columns:
    CALL {{ db }}.{{ sch }}.test_preview_bundles(TRUE);
==============================================================================*/

ALTER TASK  {{ db }}.{{ sch }}.snapshot_system_columns_task        RESUME;
ALTER ALERT {{ db }}.{{ sch }}.sys_cols_drift_alert                RESUME;
ALTER TASK  {{ db }}.{{ sch }}.refresh_watched_system_objects_task RESUME;
ALTER TASK  {{ db }}.{{ sch }}.test_preview_bundles_task           RESUME;

-- Seed the baseline and inventory now instead of waiting for the schedule
CALL {{ db }}.{{ sch }}.snapshot_system_columns();
CALL {{ db }}.{{ sch }}.refresh_watched_system_objects();
