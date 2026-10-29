CREATE TABLE IF NOT EXISTS MONITOR_DB.OPS.pool_suspend_log (
  checked_at TIMESTAMP_LTZ,
  pool_name  STRING,
  samples    NUMBER,
  busy       NUMBER,
  jobs       NUMBER,
  action     STRING
);

CREATE OR REPLACE TASK MONITOR_DB.OPS.suspend_pool_if_idle
  USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
  SCHEDULE = 'USING CRON 0,30 20-23 * * * America/New_York'
AS
DECLARE
  samples NUMBER;
  busy    NUMBER;
  jobs    NUMBER;
BEGIN
  SELECT COUNT(*), COUNT_IF(VALUE::float >= 0.05)
    INTO :samples, :busy
  FROM SNOWFLAKE.TELEMETRY.EVENTS_VIEW
  WHERE RECORD_TYPE = 'METRIC'
    AND RECORD:metric:name::string = 'container.cpu.usage'
    AND UPPER(RESOURCE_ATTRIBUTES:"snow.compute_pool.name"::string) = UPPER('<POOL_NAME>')
    AND TIMESTAMP >= DATEADD('minute', -30, SYSDATE());      -- SYSDATE() is UTC, matching the column

  SHOW SERVICES IN COMPUTE POOL <POOL_NAME>;
  SELECT COUNT_IF("is_job" = TRUE AND "status" = 'RUNNING') INTO :jobs
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

  IF (samples > 0 AND busy = 0 AND jobs = 0) THEN
    ALTER COMPUTE POOL <POOL_NAME> SUSPEND;
    INSERT INTO MONITOR_DB.OPS.pool_suspend_log
      SELECT CURRENT_TIMESTAMP(), '<POOL_NAME>', :samples, :busy, :jobs, 'suspended';
  ELSE
    INSERT INTO MONITOR_DB.OPS.pool_suspend_log
      SELECT CURRENT_TIMESTAMP(), '<POOL_NAME>', :samples, :busy, :jobs, 'skipped';
  END IF;
END;

EXECUTE TASK MONITOR_DB.OPS.suspend_pool_if_idle;

ALTER TASK MONITOR_DB.OPS.suspend_pool_if_idle RESUME;
