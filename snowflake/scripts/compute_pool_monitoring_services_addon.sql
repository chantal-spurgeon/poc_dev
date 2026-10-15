-- =====================================================================
-- ADD-ON: which services are keeping the compute pool active?
-- Run AFTER compute_pool_monitoring_sql_only.sql (uses the same schema and
-- the util_hourly table from its hourly rollup task).
--
-- Background (from Snowflake docs): a pool counts as inactive only when "no
-- services or jobs are currently active on any node in the pool". So any
-- service in RUNNING (or a job still running) keeps the pool from suspending,
-- no matter how little traffic it gets. SHOW SERVICES also has a service-level
-- AUTO_SUSPEND_SECS column (0/unset = never auto-suspends).
--
-- Not run against an account. SHOW SERVICES columns below match the docs
-- (28 columns). Check with: SHOW SERVICES IN ACCOUNT;
-- Replace MONITOR_DB.OPS if you used a different location.
-- =====================================================================

USE SCHEMA MONITOR_DB.OPS;

-- ---------------------------------------------------------------------
-- 1. Snapshot every service (and job service) every 10 minutes
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS service_state_log (
  captured_at         TIMESTAMP_LTZ,
  service_name        STRING,
  database_name       STRING,
  schema_name         STRING,
  owner               STRING,
  compute_pool        STRING,
  status              STRING,
  is_job              BOOLEAN,
  current_instances   NUMBER,
  min_instances       NUMBER,
  max_instances       NUMBER,
  auto_resume         BOOLEAN,
  auto_suspend_secs   NUMBER,
  created_on          TIMESTAMP_LTZ,
  resumed_on          TIMESTAMP_LTZ,
  suspended_on        TIMESTAMP_LTZ,
  managing_object_domain STRING,   -- e.g. set when a Streamlit object manages the service
  managing_object_name   STRING,
  comment             STRING
);

CREATE OR REPLACE TASK capture_service_state
  USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
  SCHEDULE = '10 MINUTE'
AS
BEGIN
  SHOW SERVICES IN ACCOUNT;
  INSERT INTO MONITOR_DB.OPS.service_state_log
  SELECT CURRENT_TIMESTAMP(), "name", "database_name", "schema_name", "owner",
         "compute_pool", "status", "is_job", "current_instances", "min_instances",
         "max_instances", "auto_resume", "auto_suspend_secs", "created_on",
         "resumed_on", "suspended_on", "managing_object_domain",
         "managing_object_name", "comment"
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
  DELETE FROM MONITOR_DB.OPS.service_state_log
   WHERE captured_at < DATEADD('day', -90, CURRENT_TIMESTAMP());
END;

ALTER TASK capture_service_state RESUME;

-- ---------------------------------------------------------------------
-- 2. Right now: what is holding each pool open?
--    (latest snapshot only)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_pool_keepers_now AS
SELECT
  compute_pool,
  service_name,
  database_name || '.' || schema_name        AS location,
  status,
  is_job,
  current_instances,
  min_instances,
  max_instances,
  auto_suspend_secs,
  COALESCE(auto_suspend_secs, 0) = 0          AS never_auto_suspends,
  resumed_on,
  DATEDIFF('hour', resumed_on, captured_at)   AS hours_since_resume,
  managing_object_domain,
  managing_object_name,
  owner
FROM service_state_log
WHERE captured_at = (SELECT MAX(captured_at) FROM service_state_log)
  AND status IN ('RUNNING', 'PENDING', 'SUSPENDING')
ORDER BY compute_pool, never_auto_suspends DESC, hours_since_resume DESC;

-- ---------------------------------------------------------------------
-- 3. History: hours each service spent RUNNING per day
--    (snapshot count x 10 min; approximate)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_running_hours_daily AS
SELECT
  DATE_TRUNC('day', captured_at)                         AS day,
  compute_pool,
  service_name,
  ROUND(COUNT_IF(status = 'RUNNING') * 10 / 60.0, 1)     AS approx_hours_running,
  MAX(COALESCE(auto_suspend_secs, 0))                    AS auto_suspend_secs
FROM service_state_log
GROUP BY 1, 2, 3;

-- Share of each day the pool was held open by each service. A service RUNNING
-- ~24h/day means it alone prevents the pool from ever suspending.
CREATE OR REPLACE VIEW v_service_pct_of_day AS
SELECT day, compute_pool, service_name, approx_hours_running,
       ROUND(100 * approx_hours_running / 24, 0) AS pct_of_day_running,
       auto_suspend_secs
FROM v_service_running_hours_daily;

-- ---------------------------------------------------------------------
-- 4. Running but doing nothing: services RUNNING while their container CPU
--    stayed near zero. Uses util_hourly from the hourly rollup task.
--    container.cpu.usage is in cores. Threshold 0.05 = 5% of one core;
--    tune it after looking at your real numbers (start by eyeballing the
--    query below without the HAVING).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_idle_but_running_24h AS
WITH running AS (
  SELECT compute_pool, service_name,
         COUNT_IF(status = 'RUNNING') AS running_snapshots,
         MAX(COALESCE(auto_suspend_secs, 0)) AS auto_suspend_secs
  FROM service_state_log
  WHERE captured_at >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
  GROUP BY 1, 2
),
cpu AS (
  SELECT pool_name, service,
         MAX(max_val) AS max_cpu_cores_24h,
         AVG(p50)     AS avg_cpu_cores_24h
  FROM util_hourly
  WHERE metric = 'container.cpu.usage'
    AND hour >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
  GROUP BY 1, 2
)
SELECT r.compute_pool, r.service_name, r.running_snapshots,
       ROUND(r.running_snapshots * 10 / 60.0, 1) AS approx_hours_running_24h,
       r.auto_suspend_secs,
       c.avg_cpu_cores_24h, c.max_cpu_cores_24h
FROM running r
LEFT JOIN cpu c
  ON UPPER(c.service) = UPPER(r.service_name)   -- event table may hold the name in a different case
WHERE r.running_snapshots > 0
  AND COALESCE(c.max_cpu_cores_24h, 0) < 0.05     -- <== tune
ORDER BY r.running_snapshots DESC;

-- Without the threshold, to calibrate what "idle" looks like for your apps:
-- SELECT service, AVG(p50) avg_cpu, MAX(max_val) max_cpu
-- FROM util_hourly WHERE metric='container.cpu.usage'
--   AND hour >= DATEADD('day',-7,CURRENT_TIMESTAMP()) GROUP BY 1 ORDER BY 3;

-- ---------------------------------------------------------------------
-- 5. Extend the daily scorecard with "services holding the pool open"
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_daily_keepers AS
SELECT day, compute_pool,
       COUNT_IF(approx_hours_running >= 20)                       AS services_running_20h_plus,
       COUNT_IF(approx_hours_running > 0 AND auto_suspend_secs = 0) AS running_services_without_autosuspend,
       LISTAGG(IFF(approx_hours_running >= 20, service_name, NULL), ', ')
         WITHIN GROUP (ORDER BY service_name)                     AS always_on_services
FROM v_service_running_hours_daily
GROUP BY 1, 2
ORDER BY day DESC;

-- ---------------------------------------------------------------------
-- 6. Optional alert: a pool has been continuously non-suspended for 24h+
--    while its AUTO_SUSPEND_SECS is set. Something is holding it open.
--    (Use as the condition of a Snowflake ALERT, once you have a notification
--    integration.)
-- ---------------------------------------------------------------------
-- SELECT pool_name
-- FROM pool_state_log
-- WHERE captured_at >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
-- GROUP BY pool_name
-- HAVING COUNT_IF(state = 'SUSPENDED') = 0 AND COUNT(*) > 100;   -- ~144 snapshots/day at 10 min

-- ---------------------------------------------------------------------
-- 7. What to do with the findings (changes are yours to decide; log them in
--    pool_change_log first)
-- ---------------------------------------------------------------------
--  * Service RUNNING ~24h/day, auto_suspend_secs = 0/NULL, near-zero CPU:
--      ALTER SERVICE <db.schema.svc> SET AUTO_SUSPEND_SECS = 600;
--    With AUTO_RESUME = TRUE the next request wakes it (expect a cold start).
--    Streamlit services managed by another object (managing_object_* columns
--    populated) may not accept this directly; check how they were created.
--  * Stale/test services nobody uses: DROP SERVICE (or SUSPEND SERVICE) after
--    confirming with the owner. Look at the owner/comment/created_on columns.
--  * Job services stuck in RUNNING hold the pool too; check is_job = TRUE rows.
--  * Services with min_instances > 1 hold extra capacity open; lower it if
--    traffic doesn't need it.
--
-- Teardown: ALTER TASK capture_service_state SUSPEND;
