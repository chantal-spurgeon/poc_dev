-- 1. List all compute pools and check if their state is 'IDLE' or 'RUNNING'
SHOW COMPUTE POOLS;

-- 2. List all container services deployed in your account 
SHOW SERVICES;

-- 3. Check the real-time operational status of a specific service
SELECT SYSTEM$GET_SERVICE_STATUS('my_database.my_schema.my_service');

SELECT 
    start_time,
    end_time,
    compute_pool_name,
    credits_used
FROM snowflake.account_usage.compute_pool_billing_history
WHERE start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())
ORDER BY credits_used DESC;

-- Suspending a compute pool immediately stops all containers running on it, effectively freezing billing for that compute infrastructure
ALTER COMPUTE POOL my_compute_pool SUSPEND;

-- If multiple services share a single compute pool and you only want to stop one of them, you can suspend that specific service
ALTER SERVICE my_service SUSPEND;

-- If you no longer need the service or the compute infrastructure at all, drop them to ensure they never auto-resume
DROP SERVICE my_service;
DROP COMPUTE POOL my_compute_pool;

-- If you want to keep running, but lower costs, update parameters
ALTER COMPUTE POOL my_compute_pool SET AUTO_SUSPEND = 600; -- time in seconds

-- If you want to scale down the instance, update with new .yaml config
ALTER SERVICE my_service FROM @spec_stage SPEC='new_spec.yaml';
