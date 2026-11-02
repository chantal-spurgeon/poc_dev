-- =====================================================================
-- NOTEBOOK MONITORING (separate from the Streamlit/pool monitoring)
-- Run AFTER compute_pool_monitoring_sql_only.sql: this reuses util_hourly
-- (hourly CPU/memory per service, which already covers notebook services)
-- and the same MONITOR_DB.OPS schema. Replace MONITOR_DB.OPS if different.
--
-- What it captures, in its own tables:
--   notebook_inventory_log   daily  SHOW NOTEBOOKS IN ACCOUNT (raw VARIANT)
--   notebook_describe_log    daily  DESCRIBE NOTEBOOK per notebook (raw VARIANT)
--   notebook_service_log     10 min SHOW SERVICES rows for notebook-managed services
-- Credits come from SNOWFLAKE.ACCOUNT_USAGE.NOTEBOOKS_CONTAINER_RUNTIME_HISTORY.
--
-- IMPORTANT: the docs list no idle-shutdown column for SHOW NOTEBOOKS and only
-- created_on for DESCRIBE NOTEBOOK (the real output may have more). So the
-- capture stores the WHOLE result row as VARIANT and the views pull fields out
-- by name. Run the research queries in section 6 after the first capture, and
-- adjust the field names in section 4 if they differ. NOT run against an
-- account; test the tasks by hand with EXECUTE TASK first.
--
-- Idle setting (from ALTER NOTEBOOK docs):
--   ALTER NOTEBOOK <name> SET IDLE_AUTO_SHUTDOWN_TIME_SECONDS = <60..259200>;
--   default 3600; applies to both warehouse and container runtime.
-- =====================================================================

USE SCHEMA MONITOR_DB.OPS;

-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS notebook_inventory_log (
  captured_at TIMESTAMP_LTZ,
  raw         VARIANT              -- one SHOW NOTEBOOKS row as a JSON object
);

CREATE TABLE IF NOT EXISTS notebook_describe_log (
  captured_at   TIMESTAMP_LTZ,
  database_name STRING,
  schema_name   STRING,
  notebook_name STRING,
  raw           VARIANT            -- DESCRIBE NOTEBOOK row(s) as JSON; {"error":...} if it failed
);

CREATE TABLE IF NOT EXISTS notebook_service_log (
  captured_at            TIMESTAMP_LTZ,
  service_name           STRING,
  database_name          STRING,
  schema_name            STRING,
  owner                  STRING,
  compute_pool           STRING,
  status                 STRING,
  is_job                 BOOLEAN,
  current_instances      NUMBER,
  min_instances          NUMBER,
  max_instances          NUMBER,
  auto_resume            BOOLEAN,
  auto_suspend_secs      NUMBER,
  created_on             TIMESTAMP_LTZ,
  resumed_on             TIMESTAMP_LTZ,
  suspended_on           TIMESTAMP_LTZ,
  managing_object_domain STRING,
  managing_object_name   STRING,
  comment                STRING
);

-- ---------------------------------------------------------------------
-- 2. Task A (daily): notebook inventory + per-notebook DESCRIBE
-- ---------------------------------------------------------------------
CREATE OR REPLACE TASK capture_notebook_config
  USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
  SCHEDULE = 'USING CRON 15 6 * * * America/Chicago'
AS
DECLARE
  ts TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
  c  CURSOR FOR
     SELECT raw:"database_name"::string AS db,
            raw:"schema_name"::string   AS sch,
            raw:"name"::string          AS nb
     FROM MONITOR_DB.OPS.notebook_inventory_log
     WHERE captured_at = (SELECT MAX(captured_at) FROM MONITOR_DB.OPS.notebook_inventory_log);
BEGIN
  SHOW NOTEBOOKS IN ACCOUNT;
  INSERT INTO MONITOR_DB.OPS.notebook_inventory_log
    SELECT :ts, OBJECT_CONSTRUCT(*) FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

  FOR r IN c DO
    LET v_db  STRING := r.db;
    LET v_sch STRING := r.sch;
    LET v_nb  STRING := r.nb;
    LET fq    STRING := '"' || v_db || '"."' || v_sch || '"."' || v_nb || '"';
    BEGIN
      DESCRIBE NOTEBOOK IDENTIFIER(:fq);
      INSERT INTO MONITOR_DB.OPS.notebook_describe_log
        SELECT :ts, :v_db, :v_sch, :v_nb, OBJECT_CONSTRUCT(*)
        FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
    EXCEPTION
      WHEN OTHER THEN
        INSERT INTO MONITOR_DB.OPS.notebook_describe_log
          SELECT :ts, :v_db, :v_sch, :v_nb, PARSE_JSON('{"error":"describe failed"}');
    END;
  END FOR;

  DELETE FROM MONITOR_DB.OPS.notebook_inventory_log WHERE captured_at < DATEADD('day', -90, CURRENT_TIMESTAMP());
  DELETE FROM MONITOR_DB.OPS.notebook_describe_log  WHERE captured_at < DATEADD('day', -90, CURRENT_TIMESTAMP());
END;

-- ---------------------------------------------------------------------
-- 3. Task B (every 10 min): which notebook services exist and their status
--    Filter assumes managing_object_domain mentions NOTEBOOK. Check with the
--    research query in section 6 and change the ILIKE if your value differs.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TASK capture_notebook_services
  USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
  SCHEDULE = '10 MINUTE'
AS
BEGIN
  SHOW SERVICES IN ACCOUNT;
  INSERT INTO MONITOR_DB.OPS.notebook_service_log
  SELECT CURRENT_TIMESTAMP(), "name", "database_name", "schema_name", "owner",
         "compute_pool", "status", "is_job", "current_instances", "min_instances",
         "max_instances", "auto_resume", "auto_suspend_secs", "created_on",
         "resumed_on", "suspended_on", "managing_object_domain",
         "managing_object_name", "comment"
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
  WHERE "managing_object_domain" ILIKE '%NOTEBOOK%';

  DELETE FROM MONITOR_DB.OPS.notebook_service_log
   WHERE captured_at < DATEADD('day', -90, CURRENT_TIMESTAMP());
END;

-- Start after you have checked the manual runs:
-- EXECUTE TASK capture_notebook_config;
-- EXECUTE TASK capture_notebook_services;
-- ALTER TASK capture_notebook_config   RESUME;
-- ALTER TASK capture_notebook_services RESUME;

-- ---------------------------------------------------------------------
-- 4. Views
-- ---------------------------------------------------------------------

-- Latest notebook list, with fields parsed out of the raw row
CREATE OR REPLACE VIEW v_notebook_inventory AS
SELECT captured_at,
       raw:"database_name"::string AS database_name,
       raw:"schema_name"::string   AS schema_name,
       raw:"name"::string          AS notebook_name,
       raw:"owner"::string         AS owner,
       raw:"query_warehouse"::string AS query_warehouse,
       raw:"code_warehouse"::string  AS code_warehouse,
       raw:"created_on"::string      AS created_on,
       raw:"comment"::string         AS comment
FROM notebook_inventory_log
WHERE captured_at = (SELECT MAX(captured_at) FROM notebook_inventory_log);

-- Configured idle shutdown per notebook (latest DESCRIBE).
-- FIELD NAME IS A GUESS: run section 6 query B, then edit 'idle_auto_shutdown_time_seconds'.
CREATE OR REPLACE VIEW v_notebook_idle_settings AS
SELECT d.captured_at,
       d.database_name, d.schema_name, d.notebook_name,
       TRY_TO_NUMBER(GET_IGNORE_CASE(d.raw, 'idle_auto_shutdown_time_seconds')::string) AS idle_shutdown_secs,
       GET_IGNORE_CASE(d.raw, 'runtime_name')::string   AS runtime_name,
       GET_IGNORE_CASE(d.raw, 'compute_pool')::string   AS compute_pool,
       d.raw
FROM notebook_describe_log d
WHERE d.captured_at = (SELECT MAX(captured_at) FROM notebook_describe_log);

-- Notebook services in the latest snapshot
CREATE OR REPLACE VIEW v_notebook_services_now AS
SELECT compute_pool, service_name, managing_object_name AS notebook,
       status, auto_suspend_secs, resumed_on,
       DATEDIFF('hour', resumed_on, captured_at) AS hours_since_resume,
       owner
FROM notebook_service_log
WHERE captured_at = (SELECT MAX(captured_at) FROM notebook_service_log)
  AND status IN ('RUNNING', 'PENDING', 'SUSPENDING')
ORDER BY compute_pool, hours_since_resume DESC;

-- Is it actually active? Running hours vs. CPU over the last 24h.
-- CPU comes from util_hourly (hourly rollup). Low CPU while RUNNING for many
-- hours = holding the pool open without doing work.
CREATE OR REPLACE VIEW v_notebook_activity_24h AS
WITH svc AS (
  SELECT compute_pool, service_name, managing_object_name AS notebook,
         COUNT_IF(status = 'RUNNING')                       AS snapshots_running,
         ROUND(COUNT_IF(status = 'RUNNING') * 10 / 60.0, 1) AS approx_hours_running
  FROM notebook_service_log
  WHERE captured_at >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
  GROUP BY 1, 2, 3
),
cpu AS (
  SELECT UPPER(service) AS service_u,
         MAX(max_val)   AS max_cpu_cores,
         AVG(p50)       AS avg_cpu_cores
  FROM util_hourly
  WHERE metric = 'container.cpu.usage'
    AND hour >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
  GROUP BY 1
)
SELECT s.compute_pool, s.service_name, s.notebook,
       s.approx_hours_running,
       ROUND(c.max_cpu_cores, 3) AS max_cpu_cores_24h,
       ROUND(c.avg_cpu_cores, 3) AS avg_cpu_cores_24h,
       i.idle_shutdown_secs
FROM svc s
LEFT JOIN cpu c ON c.service_u = UPPER(s.service_name)
LEFT JOIN v_notebook_idle_settings i ON UPPER(i.notebook_name) = UPPER(s.notebook)
ORDER BY s.approx_hours_running DESC;

-- Credits per notebook per day (view lags up to ~3 hours).
-- execution_hours is notebook run time; a big gap between credits and
-- execution time suggests billing while idle.
CREATE OR REPLACE VIEW v_notebook_credits_daily AS
SELECT DATE_TRUNC('day', start_time)            AS day,
       notebook_name,
       compute_pool_name,
       service_name,
       SUM(credits)                             AS credits,
       ROUND(SUM(notebook_execution_time_secs) / 3600.0, 2) AS execution_hours
FROM SNOWFLAKE.ACCOUNT_USAGE.NOTEBOOKS_CONTAINER_RUNTIME_HISTORY
GROUP BY 1, 2, 3, 4;

-- ---------------------------------------------------------------------
-- 5. Quick looks
-- ---------------------------------------------------------------------
-- SELECT * FROM v_notebook_idle_settings ORDER BY idle_shutdown_secs DESC NULLS LAST;
-- SELECT * FROM v_notebook_activity_24h;
-- SELECT * FROM v_notebook_credits_daily WHERE day >= DATEADD('day',-14,CURRENT_DATE()) ORDER BY day DESC, credits DESC;

-- ---------------------------------------------------------------------
-- 6. Research queries (run after the first captures)
-- ---------------------------------------------------------------------
-- A. What do notebook services look like in SHOW SERVICES? (confirms the section 3 filter)
--    SELECT DISTINCT managing_object_domain, managing_object_name FROM service_state_log
--    WHERE managing_object_domain IS NOT NULL;
--
-- B. What fields does DESCRIBE NOTEBOOK actually return? (confirms idle field name)
--    SELECT DISTINCT f.key
--    FROM notebook_describe_log d, LATERAL FLATTEN(INPUT => d.raw) f;
--
-- C. What does SHOW NOTEBOOKS return?
--    SELECT DISTINCT f.key FROM notebook_inventory_log i, LATERAL FLATTEN(INPUT => i.raw) f;
--
-- D. Did any DESCRIBE fail (privileges are the usual cause)?
--    SELECT * FROM notebook_describe_log WHERE raw:error IS NOT NULL;
--
-- E. Map notebooks to services/pools from billing history (works even if the
--    managing_object filter in section 3 returns nothing):
--    SELECT DISTINCT notebook_name, compute_pool_name, service_name
--    FROM SNOWFLAKE.ACCOUNT_USAGE.NOTEBOOKS_CONTAINER_RUNTIME_HISTORY
--    WHERE start_time >= DATEADD('day',-30,CURRENT_TIMESTAMP());
--
-- F. Change the idle setting (log it in pool_change_log first):
--    ALTER NOTEBOOK <db>.<schema>.<notebook> SET IDLE_AUTO_SHUTDOWN_TIME_SECONDS = 1800;

-- ---------------------------------------------------------------------
-- 7. Teardown
-- ---------------------------------------------------------------------
-- ALTER TASK capture_notebook_config   SUSPEND;
-- ALTER TASK capture_notebook_services SUSPEND;
