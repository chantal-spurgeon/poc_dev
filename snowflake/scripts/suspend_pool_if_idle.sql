CREATE OR REPLACE TASK MONITOR_DB.OPS.suspend_pool_if_idle
  USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
  SCHEDULE = 'USING CRON 0,30 20-23 * * * America/New_York'   -- tries every 30 min, 8-11:30 pm ET
AS
DECLARE
  samples NUMBER;
  busy    NUMBER;
  jobs    NUMBER;
BEGIN
  -- CPU samples for every service on the pool, last 30 minutes
  SELECT COUNT(*), COUNT_IF(VALUE::float >= 0.05)       -- 0.05 cores: tune after looking at real numbers
    INTO :samples, :busy
  FROM SNOWFLAKE.TELEMETRY.EVENTS_VIEW
  WHERE RECORD_TYPE = 'METRIC'
    AND RECORD:metric:name::string = 'container.cpu.usage'
    AND UPPER(RESOURCE_ATTRIBUTES:"snow.compute_pool.name"::string) = UPPER('<POOL_NAME>')
    AND TIMESTAMP >= DATEADD('minute', -30, CURRENT_TIMESTAMP());

  -- Any job service still running on the pool
  SHOW SERVICES IN COMPUTE POOL <POOL_NAME>;
  SELECT COUNT_IF("is_job" = TRUE AND "status" = 'RUNNING') INTO :jobs
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

  IF (samples > 0 AND busy = 0 AND jobs = 0) THEN
    ALTER COMPUTE POOL <POOL_NAME> SUSPEND;
    RETURN 'suspended';
  END IF;

  RETURN 'skipped: samples=' || samples || ' busy=' || busy || ' jobs=' || jobs;
END;

ALTER TASK MONITOR_DB.OPS.suspend_pool_if_idle RESUME;
