-- Long running workloads
SELECT 
    query_id,
    query_text,
    warehouse_name,
    user_name,
    total_elapsed_time / 1000 AS elapsed_seconds,
    compilation_time / 1000 AS compilation_seconds,
    execution_time / 1000 AS execution_seconds
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD(day, -7, CURRENT_TIMESTAMP())
  AND execution_status = 'SUCCESS'
ORDER BY total_elapsed_time DESC
LIMIT 10;

-- Long running repeated queries
SELECT 
    query_hash,
    COUNT(*) AS execution_count,
    SUM(total_elapsed_time) / 1000 AS total_elapsed_seconds,
    AVG(total_elapsed_time) / 1000 AS avg_elapsed_seconds,
    ANY_VALUE(query_id) AS sample_query_id,
    ANY_VALUE(query_text) AS sample_query_text
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD(day, -7, CURRENT_TIMESTAMP())
GROUP BY query_hash
ORDER BY total_elapsed_seconds DESC
LIMIT 10;

-- Queries with disk spillage (may need more compute resources)
SELECT 
    query_id,
    warehouse_name,
    bytes_spilled_to_local_storage,
    bytes_spilled_to_remote_storage,
    total_elapsed_time / 1000 AS elapsed_seconds
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD(day, -7, CURRENT_TIMESTAMP())
  AND (bytes_spilled_to_local_storage > 0 OR bytes_spilled_to_remote_storage > 0)
ORDER BY bytes_spilled_to_remote_storage DESC
LIMIT 10;

-- Once you have query ID, pull in Query History and look at the query profile.
-- Queuing Time: Time waiting for a compute slot. May need to add additional clusters to WH, or set STATEMENT_TIMEOUT_IN_SECONDS to abort runaway queries.
-- Cartesian products (exploding joins): Query problem. Look at adding some WHERE conditions, or use a different join type.
-- Disk Spillage: Resources are too low for the work required. Increase compute (WH size) or look at ways to limit amount of data sorted. Use GROUP BY instead of DISTINCT to lower sort overhead.
-- Excessive Scan: If no cluster keys are present, they may need to be added. If they are present, they may need to be readjusted (see cluster scripts). Avoid SELECT * and limit to only required columns.
