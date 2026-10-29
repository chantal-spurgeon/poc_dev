-- =====================================================================
-- SQL-only compute pool monitoring (no changes to the Streamlit apps)
--
-- Two small serverless tasks:
--   1. capture_pool_state   every 10 min: snapshot SHOW COMPUTE POOLS
--   2. rollup_pool_telemetry hourly: summarize the LAST COMPLETED hour of
--      event-table metrics, errors and service events into small tables.
-- Everything else is a view over those small tables or Account Usage, so
-- reviewing results never rescans the (large) raw event table.
--
-- What this CAN tell you: cost, suspend/resume frequency, capacity pressure
-- (time at max nodes), CPU/memory headroom, restarts, container errors.
-- What it CANNOT tell you: how long a user waited. That needs app-side timing
-- or a synthetic probe. Use pool_state_log + errors as proxies for now.
--
-- BEFORE RUNNING, replace:
--   MONITOR_DB.OPS              -> database.schema you own
--   SNOWFLAKE.TELEMETRY.EVENTS  -> your active event table
--                                  (SHOW PARAMETERS LIKE 'EVENT_TABLE' IN ACCOUNT)
-- Column names in SHOW output and event table resource attributes can vary by
-- version. Run the discovery queries first. I have not run this script.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS MONITOR_DB.OPS;
USE SCHEMA MONITOR_DB.OPS;

-- ---------------------------------------------------------------------
-- 0. Discovery (run once; adjust below if names differ)
-- ---------------------------------------------------------------------
-- SHOW COMPUTE POOLS;
-- SHOW SERVICES;                          -- shows which pool each service uses
-- SELECT DISTINCT OBJECT_KEYS(RESOURCE_ATTRIBUTES)
--   FROM SNOWFLAKE.TELEMETRY.EVENTS WHERE TIMESTAMP > DATEADD('hour',-1,CURRENT_TIMESTAMP()) LIMIT 5;
-- SELECT DISTINCT RECORD_TYPE FROM SNOWFLAKE.TELEMETRY.EVENTS
--   WHERE TIMESTAMP > DATEADD('hour',-1,CURRENT_TIMESTAMP());
-- SELECT DISTINCT RECORD:metric:name::string FROM SNOWFLAKE.TELEMETRY.EVENTS
--   WHERE RECORD_TYPE='METRIC' AND TIMESTAMP > DATEADD('hour',-1,CURRENT_TIMESTAMP());
-- SELECT DISTINCT RECORD:name::string FROM SNOWFLAKE.TELEMETRY.EVENTS
--   WHERE RECORD_TYPE='EVENT' AND TIMESTAMP > DATEADD('day',-7,CURRENT_TIMESTAMP());

-- ---------------------------------------------------------------------
-- 1. Change log: record settings before/after each change (rollback aid)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pool_change_log (
  changed_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  pool_name  STRING,
  setting    STRING,
  old_value  STRING,
  new_value  STRING,
  note       STRING
);
-- Example (edit, then run alongside the ALTER):
-- INSERT INTO pool_change_log (pool_name, setting, old_value, new_value, note)
-- VALUES ('MY_POOL','AUTO_SUSPEND_SECS','3600','600','cost reduction');
-- ALTER COMPUTE POOL MY_POOL SET AUTO_SUSPEND_SECS = 600;

-- ---------------------------------------------------------------------
-- 2. Task 1: pool state snapshots every 10 minutes
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pool_state_log (
  captured_at       TIMESTAMP_LTZ,
  pool_name         STRING,
  state             STRING,
  min_nodes         NUMBER,
  max_nodes         NUMBER,
  active_nodes      NUMBER,
  idle_nodes        NUMBER,
  target_nodes      NUMBER,
  auto_suspend_secs NUMBER,
  instance_family   STRING,
  num_services      NUMBER,
  num_jobs          NUMBER
);

CREATE OR REPLACE TASK capture_pool_state
  USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'   -- serverless: no warehouse to keep warm
  SCHEDULE = '10 MINUTE'
AS
BEGIN
  SHOW COMPUTE POOLS;
  INSERT INTO MONITOR_DB.OPS.pool_state_log
  SELECT CURRENT_TIMESTAMP(), "name", "state", "min_nodes", "max_nodes",
         "active_nodes", "idle_nodes", "target_nodes", "auto_suspend_secs",
         "instance_family", "num_services", "num_jobs"
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
END;

-- ---------------------------------------------------------------------
-- 3. Task 2: hourly rollup of the last completed hour of event-table data
--    Idempotent: deletes then reinserts that hour, so a retry can't duplicate.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS util_hourly (
  hour      TIMESTAMP_LTZ,
  pool_name STRING,
  service   STRING,
  metric    STRING,
  p50       FLOAT,
  p95       FLOAT,
  max_val   FLOAT
);

CREATE TABLE IF NOT EXISTS errors_hourly (
  hour        TIMESTAMP_LTZ,
  pool_name   STRING,
  service     STRING,
  error_lines NUMBER
);

CREATE TABLE IF NOT EXISTS service_events_hourly (
  hour       TIMESTAMP_LTZ,
  pool_name  STRING,
  service    STRING,
  event_name STRING,
  events     NUMBER
);

CREATE OR REPLACE TASK MONITOR_DB.OPS.rollup_pool_telemetry
  USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
  SCHEDULE = 'USING CRON 5 * * * * America/Chicago'
AS
DECLARE
  -- the hour as a real instant (for the stored labels)
  h_start     TIMESTAMP_LTZ DEFAULT DATEADD('hour', -1, DATE_TRUNC('hour', CURRENT_TIMESTAMP()));
  h_end       TIMESTAMP_LTZ DEFAULT DATE_TRUNC('hour', CURRENT_TIMESTAMP());
  -- the same hour as UTC wall-clock time (for comparing to the event table)
  h_start_utc TIMESTAMP_NTZ DEFAULT CONVERT_TIMEZONE('UTC', DATEADD('hour', -1, DATE_TRUNC('hour', CURRENT_TIMESTAMP())))::TIMESTAMP_NTZ;
  h_end_utc   TIMESTAMP_NTZ DEFAULT CONVERT_TIMEZONE('UTC', DATE_TRUNC('hour', CURRENT_TIMESTAMP()))::TIMESTAMP_NTZ;
BEGIN
  DELETE FROM MONITOR_DB.OPS.util_hourly WHERE hour = :h_start;
  INSERT INTO MONITOR_DB.OPS.util_hourly
  SELECT :h_start,
         RESOURCE_ATTRIBUTES:"snow.compute_pool.name"::string,
         RESOURCE_ATTRIBUTES:"snow.service.name"::string,
         RECORD:metric:name::string,
         APPROX_PERCENTILE(VALUE::float, 0.50),
         APPROX_PERCENTILE(VALUE::float, 0.95),
         MAX(VALUE::float)
  FROM SNOWFLAKE.TELEMETRY.EVENTS_VIEW
  WHERE RECORD_TYPE = 'METRIC'
    AND TIMESTAMP >= :h_start_utc AND TIMESTAMP < :h_end_utc
    AND RECORD:metric:name::string IN
        ('container.cpu.usage','container.cpu.requested','container.cpu.limit','container.memory.usage')
  GROUP BY 2, 3, 4;

  DELETE FROM MONITOR_DB.OPS.errors_hourly WHERE hour = :h_start;
  INSERT INTO MONITOR_DB.OPS.errors_hourly
  SELECT :h_start,
         RESOURCE_ATTRIBUTES:"snow.compute_pool.name"::string,
         RESOURCE_ATTRIBUTES:"snow.service.name"::string,
         COUNT(*)
  FROM SNOWFLAKE.TELEMETRY.EVENTS_VIEW
  WHERE RECORD_TYPE = 'LOG'
    AND TIMESTAMP >= :h_start_utc AND TIMESTAMP < :h_end_utc
    AND REGEXP_LIKE(VALUE::string, '.*(Traceback|ERROR|Exception|MemoryError|OOM|timed? ?out).*', 'is')
  GROUP BY 2, 3;

  DELETE FROM MONITOR_DB.OPS.service_events_hourly WHERE hour = :h_start;
  INSERT INTO MONITOR_DB.OPS.service_events_hourly
  SELECT :h_start,
         RESOURCE_ATTRIBUTES:"snow.compute_pool.name"::string,
         RESOURCE_ATTRIBUTES:"snow.service.name"::string,
         RECORD:name::string,
         COUNT(*)
  FROM SNOWFLAKE.TELEMETRY.EVENTS_VIEW
  WHERE RECORD_TYPE = 'EVENT'
    AND TIMESTAMP >= :h_start_utc AND TIMESTAMP < :h_end_utc
  GROUP BY 2, 3, 4;

  DELETE FROM MONITOR_DB.OPS.pool_state_log        WHERE captured_at < DATEADD('day', -90, CURRENT_TIMESTAMP());
  DELETE FROM MONITOR_DB.OPS.util_hourly           WHERE hour        < DATEADD('day', -90, CURRENT_TIMESTAMP());
  DELETE FROM MONITOR_DB.OPS.errors_hourly         WHERE hour        < DATEADD('day', -90, CURRENT_TIMESTAMP());
  DELETE FROM MONITOR_DB.OPS.service_events_hourly WHERE hour        < DATEADD('day', -90, CURRENT_TIMESTAMP());
END;

-- Start both tasks (owning role needs EXECUTE MANAGED TASK on the account,
-- plus read access to the event table and USAGE on the monitoring schema):
ALTER TASK capture_pool_state    RESUME;
ALTER TASK rollup_pool_telemetry RESUME;

-- ---------------------------------------------------------------------
-- 4. Views for reviewing results (cheap: they read the small tables)
-- ---------------------------------------------------------------------

-- Pool behavior per day: suspends/resumes, capacity pressure, idle share
CREATE OR REPLACE VIEW v_pool_daily AS
WITH s AS (
  SELECT *, LAG(state) OVER (PARTITION BY pool_name ORDER BY captured_at) AS prev_state
  FROM pool_state_log
)
SELECT
  DATE_TRUNC('day', captured_at) AS day,
  pool_name,
  COUNT_IF(state = 'SUSPENDED' AND prev_state IS DISTINCT FROM 'SUSPENDED') AS suspends,
  COUNT_IF(state = 'STARTING'  AND prev_state IS DISTINCT FROM 'STARTING')  AS resumes,
  ROUND(100 * COUNT_IF(active_nodes + idle_nodes >= max_nodes AND state <> 'SUSPENDED')
        / NULLIFZERO(COUNT_IF(state <> 'SUSPENDED')), 1) AS pct_time_at_max_nodes,
  ROUND(100 * COUNT_IF(state = 'IDLE') / NULLIFZERO(COUNT(*)), 1) AS pct_snapshots_idle,
  MAX(active_nodes) AS peak_active_nodes
FROM s
GROUP BY 1, 2;

-- Credits per day (Account Usage lags by up to a few hours)
CREATE OR REPLACE VIEW v_pool_credits_daily AS
SELECT DATE_TRUNC('day', start_time) AS day,
       compute_pool_name AS pool_name,
       SUM(credits_used) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWPARK_CONTAINER_SERVICES_HISTORY
GROUP BY 1, 2;

-- Peak-hour headroom per service (last 7 days). Compare p95 usage to requested/limit.
CREATE OR REPLACE VIEW v_headroom_7d AS
SELECT pool_name, service, metric,
       MAX(p95)     AS peak_p95,
       AVG(p50)     AS avg_p50,
       MAX(max_val) AS absolute_max
FROM util_hourly
WHERE hour >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3;

-- One daily scorecard: cost vs capacity vs health
CREATE OR REPLACE VIEW v_daily_scorecard AS
SELECT
  c.day,
  c.pool_name,
  c.credits,
  p.suspends,
  p.resumes,
  p.pct_time_at_max_nodes,
  p.peak_active_nodes,
  COALESCE(e.error_lines, 0)     AS error_lines,
  COALESCE(ev.restart_like, 0)   AS restart_like_events
FROM v_pool_credits_daily c
LEFT JOIN v_pool_daily p
  ON p.day = c.day AND p.pool_name = c.pool_name
LEFT JOIN (
  SELECT DATE_TRUNC('day', hour) AS day, pool_name, SUM(error_lines) AS error_lines
  FROM errors_hourly GROUP BY 1, 2
) e ON e.day = c.day AND e.pool_name = c.pool_name
LEFT JOIN (
  -- Event names vary; adjust the filter after running the discovery query.
  SELECT DATE_TRUNC('day', hour) AS day, pool_name, SUM(events) AS restart_like
  FROM service_events_hourly
  WHERE REGEXP_LIKE(LOWER(event_name), '.*(restart|oom|crash|evict|terminat|fail).*')
  GROUP BY 1, 2
) ev ON ev.day = c.day AND ev.pool_name = c.pool_name
ORDER BY c.day DESC;

-- ---------------------------------------------------------------------
-- 5. Optional: warehouse side. If the Streamlit apps query a warehouse, slow
--    queries there look like "slow dashboards" but are not a pool problem.
--    Replace APP_WH and compare weeks before/after.
-- ---------------------------------------------------------------------
-- SELECT DATE_TRUNC('day', start_time) AS day,
--        COUNT(*) AS queries,
--        APPROX_PERCENTILE(total_elapsed_time, 0.95) / 1000 AS p95_secs,
--        AVG(queued_overload_time) / 1000 AS avg_queued_secs
-- FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- WHERE warehouse_name = 'APP_WH' AND start_time >= DATEADD('day',-30,CURRENT_TIMESTAMP())
-- GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------
-- 6. How to read the scorecard after your change
-- ---------------------------------------------------------------------
--  credits down, others flat                  -> savings without user impact (so far)
--  pct_time_at_max_nodes climbing at peak      -> MAX_NODES too low; raise it a step
--  resumes up + error_lines/restarts up        -> AUTO_SUSPEND_SECS too aggressive, or
--                                                 cold starts causing timeouts; raise it,
--                                                 or consider a warm-up before the workday
--  peak memory p95 near limit                 -> OOM risk; raise requests or instance size
--  Ask a few users for first-load-of-the-morning feedback in the first week; that's
--  the one thing this SQL can't measure.

-- ---------------------------------------------------------------------
-- 7. Teardown (stop the monitoring if you no longer need it)
-- ---------------------------------------------------------------------
-- ALTER TASK capture_pool_state    SUSPEND;
-- ALTER TASK rollup_pool_telemetry SUSPEND;
