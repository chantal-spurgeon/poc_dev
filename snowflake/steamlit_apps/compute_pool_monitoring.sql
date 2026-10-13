-- =====================================================================
-- Compute pool monitoring for Streamlit apps (Snowpark Container Services)
-- Purpose: verify that lower MAX_NODES / AUTO_SUSPEND_SECS did not hurt users.
--
-- BEFORE RUNNING: replace the placeholders below.
--   MONITOR_DB.OPS            -> database.schema you own for monitoring objects
--   MY_POOL                   -> your compute pool name (or remove the filter)
--   SNOWFLAKE.TELEMETRY.EVENTS-> your account's active event table
--                                (SHOW PARAMETERS LIKE 'EVENT_TABLE' IN ACCOUNT)
-- Column names in SHOW output and event table resource attributes can vary by
-- version. Run the discovery queries in section 0 and adjust if needed.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS MONITOR_DB.OPS;
USE SCHEMA MONITOR_DB.OPS;

-- ---------------------------------------------------------------------
-- 0. Discovery (run once, adjust the views below if names differ)
-- ---------------------------------------------------------------------
-- SHOW COMPUTE POOLS;
-- SELECT DISTINCT RECORD_TYPE FROM SNOWFLAKE.TELEMETRY.EVENTS WHERE TIMESTAMP > DATEADD('day',-1,CURRENT_TIMESTAMP());
-- SELECT DISTINCT RECORD:metric:name::string FROM SNOWFLAKE.TELEMETRY.EVENTS
--   WHERE RECORD_TYPE='METRIC' AND TIMESTAMP > DATEADD('day',-1,CURRENT_TIMESTAMP());
-- SELECT DISTINCT RECORD:name::string FROM SNOWFLAKE.TELEMETRY.EVENTS
--   WHERE RECORD_TYPE='EVENT' AND TIMESTAMP > DATEADD('day',-7,CURRENT_TIMESTAMP());
-- SELECT DISTINCT OBJECT_KEYS(RESOURCE_ATTRIBUTES) FROM SNOWFLAKE.TELEMETRY.EVENTS LIMIT 10;

-- ---------------------------------------------------------------------
-- 1. Baseline + change log (record settings BEFORE and AFTER each change,
--    so rollback is a copy/paste ALTER COMPUTE POOL)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pool_change_log (
  changed_at   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  pool_name    STRING,
  setting      STRING,       -- e.g. MAX_NODES, AUTO_SUSPEND_SECS
  old_value    STRING,
  new_value    STRING,
  note         STRING
);

-- Example entry (edit values, then run when you make the change):
-- INSERT INTO pool_change_log (pool_name, setting, old_value, new_value, note)
-- VALUES ('MY_POOL','MAX_NODES','10','4','cost reduction, per review 2026-10-13');
-- ALTER COMPUTE POOL MY_POOL SET MAX_NODES = 4;

-- ---------------------------------------------------------------------
-- 2. Pool state snapshots (Account Usage only gives hourly credits, so we
--    log state ourselves). Serverless task: no warehouse to keep warm.
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
  USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
  SCHEDULE = '5 MINUTE'
AS
BEGIN
  SHOW COMPUTE POOLS;
  INSERT INTO MONITOR_DB.OPS.pool_state_log
  SELECT CURRENT_TIMESTAMP(), "name", "state", "min_nodes", "max_nodes",
         "active_nodes", "idle_nodes", "target_nodes", "auto_suspend_secs",
         "instance_family", "num_services", "num_jobs"
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
END;

ALTER TASK capture_pool_state RESUME;
-- Needs EXECUTE MANAGED TASK on the account for the owning role.

-- ---------------------------------------------------------------------
-- 3. Pool behavior: suspend frequency, time at max nodes
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_pool_daily AS
WITH s AS (
  SELECT *,
         LAG(state) OVER (PARTITION BY pool_name ORDER BY captured_at) AS prev_state
  FROM pool_state_log
)
SELECT
  DATE_TRUNC('day', captured_at)                                   AS day,
  pool_name,
  COUNT_IF(state = 'SUSPENDED' AND prev_state IS DISTINCT FROM 'SUSPENDED') AS suspends,
  COUNT_IF(state = 'STARTING'  AND prev_state IS DISTINCT FROM 'STARTING')  AS resumes,
  -- share of snapshots at or above max nodes = capacity pressure
  ROUND(100 * COUNT_IF(active_nodes + idle_nodes >= max_nodes AND state <> 'SUSPENDED')
        / NULLIFZERO(COUNT_IF(state <> 'SUSPENDED')), 1)           AS pct_time_at_max_nodes,
  ROUND(100 * COUNT_IF(state = 'IDLE')
        / NULLIFZERO(COUNT(*)), 1)                                  AS pct_snapshots_idle,
  MAX(active_nodes)                                                 AS peak_active_nodes
FROM s
GROUP BY 1, 2;

-- Cold-start candidates: every STARTING episode with its observed length
-- (resolution = snapshot interval, so treat as approximate)
CREATE OR REPLACE VIEW v_pool_starts AS
SELECT pool_name, captured_at AS starting_seen_at,
       DATEDIFF('second', captured_at,
         LEAD(captured_at) OVER (PARTITION BY pool_name ORDER BY captured_at)) AS secs_to_next_snapshot,
       state
FROM pool_state_log
QUALIFY state = 'STARTING';

-- ---------------------------------------------------------------------
-- 4. Credits (hourly, lags by up to a few hours)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_pool_credits_daily AS
SELECT DATE_TRUNC('day', start_time) AS day,
       compute_pool_name,
       SUM(credits_used)             AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWPARK_CONTAINER_SERVICES_HISTORY
GROUP BY 1, 2;

-- ---------------------------------------------------------------------
-- 5. Container utilization from platform metrics (hourly p50 / p95)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_container_utilization AS
SELECT
  DATE_TRUNC('hour', TIMESTAMP)                                   AS hour,
  RESOURCE_ATTRIBUTES:"snow.service.name"::string                 AS service,
  RECORD:metric:name::string                                      AS metric,
  APPROX_PERCENTILE(VALUE::float, 0.50)                           AS p50,
  APPROX_PERCENTILE(VALUE::float, 0.95)                           AS p95,
  MAX(VALUE::float)                                               AS max_val
FROM SNOWFLAKE.TELEMETRY.EVENTS
WHERE RECORD_TYPE = 'METRIC'
  AND RECORD:metric:name::string IN
      ('container.cpu.usage','container.cpu.requested','container.cpu.limit',
       'container.memory.usage')
  AND TIMESTAMP >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3;

-- Memory/CPU headroom at peak (compare p95 usage to requested/limit)
-- SELECT service, metric, MAX(p95) FROM v_container_utilization
--  WHERE hour >= DATEADD('day',-7,CURRENT_TIMESTAMP()) GROUP BY 1,2 ORDER BY 1,2;

-- ---------------------------------------------------------------------
-- 6. Service events and errors (restarts, OOM, crashes)
-- ---------------------------------------------------------------------
-- Instance lifecycle events (names vary; use the discovery query in section 0)
CREATE OR REPLACE VIEW v_service_events AS
SELECT TIMESTAMP AS ts,
       RESOURCE_ATTRIBUTES:"snow.service.name"::string AS service,
       RECORD:name::string                              AS event_name,
       VALUE::string                                    AS detail
FROM SNOWFLAKE.TELEMETRY.EVENTS
WHERE RECORD_TYPE = 'EVENT'
  AND TIMESTAMP >= DATEADD('day', -30, CURRENT_TIMESTAMP());

-- Error-ish log lines per service per hour
CREATE OR REPLACE VIEW v_service_errors_hourly AS
SELECT DATE_TRUNC('hour', TIMESTAMP)                     AS hour,
       RESOURCE_ATTRIBUTES:"snow.service.name"::string   AS service,
       COUNT(*)                                          AS error_lines
FROM SNOWFLAKE.TELEMETRY.EVENTS
WHERE RECORD_TYPE = 'LOG'
  AND TIMESTAMP >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  AND REGEXP_LIKE(VALUE::string, '.*(Traceback|ERROR|Exception|MemoryError|OOM|timed? ?out).*', 'is')
GROUP BY 1, 2;

-- ---------------------------------------------------------------------
-- 7. App-side timing (from streamlit_timing.py: lines prefixed APPTIMING)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_app_timing AS
WITH raw AS (
  SELECT TIMESTAMP AS ts,
         RESOURCE_ATTRIBUTES:"snow.service.name"::string AS service,
         TRY_PARSE_JSON(REGEXP_SUBSTR(VALUE::string, '\\{.*\\}')) AS j
  FROM SNOWFLAKE.TELEMETRY.EVENTS
  WHERE RECORD_TYPE = 'LOG'
    AND VALUE::string LIKE 'APPTIMING %'
    AND TIMESTAMP >= DATEADD('day', -30, CURRENT_TIMESTAMP())
)
SELECT ts, service,
       j:app::string                    AS app,
       j:evt::string                    AS evt,
       j:label::string                  AS label,
       j:status::string                 AS status,
       j:run_ms::float                  AS run_ms,
       j:first_in_session::boolean      AS first_in_session,
       j:first_in_process::boolean      AS first_in_process,
       j:process_age_s::float           AS process_age_s
FROM raw
WHERE j IS NOT NULL;

-- Hourly user-facing latency per app
CREATE OR REPLACE VIEW v_app_latency_hourly AS
SELECT DATE_TRUNC('hour', ts) AS hour, service, app,
       COUNT(*)                                        AS runs,
       APPROX_PERCENTILE(run_ms, 0.50)                 AS p50_ms,
       APPROX_PERCENTILE(run_ms, 0.95)                 AS p95_ms,
       COUNT_IF(status = 'error')                      AS errors,
       APPROX_PERCENTILE(IFF(first_in_session, run_ms, NULL), 0.95) AS first_load_p95_ms
FROM v_app_timing
WHERE evt = 'app_run'
GROUP BY 1, 2, 3;

-- Cold starts: first run in a fresh container process, shortly after it started
CREATE OR REPLACE VIEW v_app_cold_starts AS
SELECT ts, service, app, run_ms, process_age_s
FROM v_app_timing
WHERE evt = 'app_run' AND first_in_process = TRUE;

-- ---------------------------------------------------------------------
-- 8. One combined daily scorecard: cost vs. capacity vs. user experience
--    Compare 1-2 weeks before the change to 1-2 weeks after.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_daily_scorecard AS
SELECT
  c.day,
  c.compute_pool_name                         AS pool_name,
  c.credits,
  p.suspends,
  p.resumes,
  p.pct_time_at_max_nodes,
  p.peak_active_nodes,
  a.runs,
  a.p95_ms,
  a.errors,
  a.first_load_p95_ms
FROM v_pool_credits_daily c
LEFT JOIN v_pool_daily p
  ON p.day = c.day AND p.pool_name = c.compute_pool_name
LEFT JOIN (
  SELECT DATE_TRUNC('day', hour) AS day,
         SUM(runs) AS runs,
         MAX(p95_ms) AS p95_ms,
         SUM(errors) AS errors,
         MAX(first_load_p95_ms) AS first_load_p95_ms
  FROM v_app_latency_hourly
  GROUP BY 1
) a ON a.day = c.day
ORDER BY c.day DESC;
-- Note: v_app_latency_hourly is per service, not per pool. If you run apps on
-- multiple pools, join through a service->pool mapping (SHOW SERVICES gives
-- compute_pool for each service) rather than the day-level join above.

-- ---------------------------------------------------------------------
-- 9. Optional alerts (examples; create a notification integration first)
-- ---------------------------------------------------------------------
-- Pool pinned at max nodes during business hours:
--   SELECT 1 FROM pool_state_log
--   WHERE captured_at > DATEADD('minute',-30,CURRENT_TIMESTAMP())
--     AND state <> 'SUSPENDED' AND active_nodes + idle_nodes >= max_nodes
--   HAVING COUNT(*) >= 5;
-- First-load p95 above tolerance:
--   SELECT 1 FROM v_app_latency_hourly
--   WHERE hour >= DATEADD('hour',-2,CURRENT_TIMESTAMP()) AND first_load_p95_ms > 60000;
