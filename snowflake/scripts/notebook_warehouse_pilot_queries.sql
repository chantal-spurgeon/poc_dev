/* =====================================================================
   Notebook warehouse vs. container pilot: discovery and measurement queries
   Run as a role with access to SNOWFLAKE.ACCOUNT_USAGE.
   Latency: NOTEBOOKS_CONTAINER_RUNTIME_HISTORY can lag up to 3 hours,
   and QUERY_ATTRIBUTION_HISTORY can lag up to about 8 hours. Wait at least
   a day after a pilot run before you compare numbers.
   Column names marked "verify" were not confirmed. Run SELECT * ... LIMIT 10 first.
   ===================================================================== */

SET lookback_start = DATEADD(day, -60, CURRENT_TIMESTAMP());
SET shared_wh      = 'WH_COMMON';

/* ---------------------------------------------------------------------
   PHASE 1: CLASSIFY (workspaces, legacy notebooks, external hosting)
   --------------------------------------------------------------------- */

-- 1a. Legacy notebook objects and their runtime settings.
--     Look for: runtime (warehouse or container), query_warehouse, compute_pool,
--     idle_auto_shutdown_time_seconds. The column set varies by release (verify).
SHOW NOTEBOOKS IN ACCOUNT;
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- 1b. Every notebook that used container credits in the window.
--     Notebooks that show up here but not in 1a are probably Notebooks in
--     Workspaces, which run on Container Runtime only.
SELECT notebook_name,
       notebook_id,
       compute_pool_name,
       COUNT(DISTINCT user_name)              AS users,
       COUNT(*)                               AS billed_hours,
       SUM(credits)                           AS container_credits,
       MIN(start_time)                        AS first_seen,
       MAX(start_time)                        AS last_seen
FROM snowflake.account_usage.notebooks_container_runtime_history
WHERE start_time >= $lookback_start
GROUP BY ALL
ORDER BY container_credits DESC;

-- 1c. External hosting (Jupyter, VS Code, scripts): which client tools hit WH_Common
--     and the other query warehouses. Look for Python connector or Snowpark
--     sessions with notebook-like patterns (many short queries per session).
SELECT s.client_application_id,
       PARSE_JSON(s.client_environment):APPLICATION::string  AS client_app,   -- verify key name
       COUNT(DISTINCT q.user_name)                            AS users,
       COUNT(*)                                               AS queries,
       SUM(q.execution_time)/1000/3600                        AS exec_hours
FROM snowflake.account_usage.query_history q
JOIN snowflake.account_usage.sessions s ON s.session_id = q.session_id
WHERE q.start_time >= $lookback_start
GROUP BY ALL
ORDER BY queries DESC;

/* ---------------------------------------------------------------------
   PHASE 2: BASELINE (refresh the September 2 snapshot)
   --------------------------------------------------------------------- */

-- 2a. Share of SPCS credits that came from notebooks, by month. Use this to
--     check whether the 95.2% figure still holds.
WITH spcs AS (
  SELECT DATE_TRUNC('month', usage_date) AS mth, SUM(credits_used) AS spcs_credits
  FROM snowflake.account_usage.metering_daily_history
  WHERE service_type = 'SNOWPARK_CONTAINER_SERVICES'
    AND usage_date >= $lookback_start::date
  GROUP BY 1),
nb AS (
  SELECT DATE_TRUNC('month', start_time)::date AS mth, SUM(credits) AS nb_credits
  FROM snowflake.account_usage.notebooks_container_runtime_history
  WHERE start_time >= $lookback_start
  GROUP BY 1)
SELECT spcs.mth, spcs_credits, nb_credits,
       ROUND(100 * nb_credits / NULLIF(spcs_credits,0), 1) AS pct_notebooks
FROM spcs LEFT JOIN nb USING (mth)
ORDER BY 1;

-- 2b. Compute pool configuration. Look for: instance family (is it larger than
--     these SQL notebooks need?), MIN/MAX_NODES, AUTO_SUSPEND_SECS.
SHOW COMPUTE POOLS;

-- 2c. KEY QUESTION: are container credits paying for work or for idle kernels?
--     SQL runs on the query warehouse in both runtimes, so container credits mostly
--     pay for the Python kernel being up. For each notebook-hour, check whether
--     the same user ran queries in that hour.
--     This is a proxy that matches on user and hour, so treat it as directional.
WITH nb AS (
  SELECT notebook_name, user_name, DATE_TRUNC('hour', start_time) AS hr, SUM(credits) AS credits
  FROM snowflake.account_usage.notebooks_container_runtime_history
  WHERE start_time >= $lookback_start
  GROUP BY ALL),
q AS (
  SELECT user_name, DATE_TRUNC('hour', start_time) AS hr,
         COUNT(*) AS queries, SUM(execution_time)/1000 AS exec_sec
  FROM snowflake.account_usage.query_history
  WHERE start_time >= $lookback_start
    AND warehouse_name IS NOT NULL
  GROUP BY ALL)
SELECT nb.notebook_name,
       SUM(nb.credits)                                               AS container_credits,
       COUNT(*)                                                      AS billed_hours,
       COUNT_IF(COALESCE(q.queries,0) = 0)                           AS hours_with_zero_queries,
       ROUND(100 * COUNT_IF(COALESCE(q.queries,0)=0) / COUNT(*), 1)  AS pct_idle_hours,
       SUM(q.exec_sec)/3600                                          AS query_exec_hours
FROM nb LEFT JOIN q ON q.user_name = nb.user_name AND q.hr = nb.hr
GROUP BY 1
ORDER BY container_credits DESC;

/* ---------------------------------------------------------------------
   PHASE 3: WH_COMMON CAPACITY (can it absorb more load?)
   --------------------------------------------------------------------- */

-- 3a. Hourly profile of credits and load. Look for: hours where avg_queued_load > 0
--     or avg_running is already high. Those hours are when added notebook load hurts.
SELECT DATE_PART('dow', l.start_time)  AS dow,
       DATE_PART('hour', l.start_time) AS hr,
       ROUND(AVG(l.avg_running),2)              AS avg_running,
       ROUND(AVG(l.avg_queued_load),3)          AS avg_queued_load,
       ROUND(MAX(l.avg_queued_load),3)          AS max_queued_load,
       ROUND(AVG(l.avg_queued_provisioning),3)  AS avg_queued_prov
FROM snowflake.account_usage.warehouse_load_history l
WHERE l.warehouse_name = $shared_wh
  AND l.start_time >= $lookback_start
GROUP BY ALL
ORDER BY dow, hr;

-- 3b. Daily credits and how many hours WH_Common was up. If it is already awake
--     most of the business day, extra notebook load during those hours costs
--     little more. Notebook use outside those hours shows up as new spend.
SELECT DATE_TRUNC('day', start_time) AS d,
       SUM(credits_used_compute)     AS compute_credits,
       COUNT_IF(credits_used_compute > 0) AS active_hours
FROM snowflake.account_usage.warehouse_metering_history
WHERE warehouse_name = $shared_wh
  AND start_time >= $lookback_start
GROUP BY 1 ORDER BY 1;

-- 3c. Queueing that users actually experience, by day (p50/p95 queue time and
--     peak concurrency). Use this as the "before" baseline for the pilot.
SELECT DATE_TRUNC('day', start_time) AS d,
       COUNT(*)                                                     AS queries,
       COUNT_IF(queued_overload_time > 0)                           AS queued_queries,
       APPROX_PERCENTILE(queued_overload_time, 0.5)/1000            AS p50_queue_s,
       APPROX_PERCENTILE(queued_overload_time, 0.95)/1000           AS p95_queue_s,
       APPROX_PERCENTILE(total_elapsed_time, 0.95)/1000             AS p95_elapsed_s
FROM snowflake.account_usage.query_history
WHERE warehouse_name = $shared_wh
  AND start_time >= $lookback_start
GROUP BY 1 ORDER BY 1;

-- 3d. Who uses WH_Common today (top roles and users by attributed credits).
--     Use this to judge the blast radius if notebooks slow it down.
SELECT q.role_name, q.user_name,
       COUNT(*)                         AS queries,
       SUM(a.credits_attributed_compute) AS attributed_credits
FROM snowflake.account_usage.query_history q
JOIN snowflake.account_usage.query_attribution_history a ON a.query_id = q.query_id
WHERE q.warehouse_name = $shared_wh
  AND q.start_time >= $lookback_start
GROUP BY ALL
ORDER BY attributed_credits DESC
LIMIT 25;

/* ---------------------------------------------------------------------
   PHASE 4: PILOT MEASUREMENT (same notebook, same inputs, both runtimes)
   Before each run:  ALTER SESSION SET QUERY_TAG = 'nbpilot|<notebook>|<runtime>|<run_id>';
   (or set it in the notebook's first cell)
   --------------------------------------------------------------------- */

-- 4a. Query-side cost and experience per pilot run.
SELECT SPLIT_PART(q.query_tag,'|',2) AS notebook,
       SPLIT_PART(q.query_tag,'|',3) AS runtime,
       SPLIT_PART(q.query_tag,'|',4) AS run_id,
       q.warehouse_name,
       MIN(q.start_time) AS run_start, MAX(q.end_time) AS run_end,
       DATEDIFF('second', MIN(q.start_time), MAX(q.end_time)) AS wall_clock_s,
       COUNT(*)                                     AS queries,
       SUM(q.execution_time)/1000                   AS exec_s,
       SUM(q.queued_overload_time)/1000             AS queued_s,
       SUM(a.credits_attributed_compute)            AS attributed_wh_credits
FROM snowflake.account_usage.query_history q
LEFT JOIN snowflake.account_usage.query_attribution_history a ON a.query_id = q.query_id
WHERE q.query_tag ILIKE 'nbpilot|%'
GROUP BY ALL
ORDER BY notebook, run_id, runtime;

-- 4b. Container credits for the same runs. Join to 4a by notebook and run window,
--     then add them up to get total affected credits.
SELECT notebook_name, user_name, start_time, end_time, credits
FROM snowflake.account_usage.notebooks_container_runtime_history
WHERE notebook_name IN ('<pilot_nb_1>','<pilot_nb_2>')
  AND start_time >= '<pilot_start>'::timestamp_ltz
ORDER BY notebook_name, start_time;

-- 4c. Warehouse-runtime runs started with EXECUTE NOTEBOOK (scheduled or tasks).
--     This is the method Snowflake documents.
SELECT q.query_text, q.user_name, q.start_time, q.total_elapsed_time/1000 AS elapsed_s,
       a.credits_attributed_compute AS wh_credits
FROM snowflake.account_usage.query_history q
JOIN snowflake.account_usage.query_attribution_history a ON a.query_id = q.query_id
WHERE q.query_text ILIKE 'execute notebook%'
  AND q.start_time >= $lookback_start;

-- 4d. Shifted cost on WH_Common: compare metered credits per hour in the pilot
--     window with the same weekday and hour in the baseline. Attribution leaves
--     out idle time, so the metered change is the true marginal cost.
SELECT DATE_TRUNC('hour', start_time) AS hr, credits_used_compute
FROM snowflake.account_usage.warehouse_metering_history
WHERE warehouse_name = $shared_wh
  AND start_time BETWEEN '<pilot_start>'::timestamp_ltz AND '<pilot_end>'::timestamp_ltz
ORDER BY 1;
