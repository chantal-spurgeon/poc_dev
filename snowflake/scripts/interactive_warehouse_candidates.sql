/*
  Interactive warehouse candidate finder
  ---------------------------------------
  Scores each warehouse on whether it looks like a good fit for an interactive warehouse:
    - Runs most of the day (interactive warehouses bill a 1-hour minimum per resume and
      have a 24-hour minimum AUTO_SUSPEND, so they are effectively always on)
    - Rarely suspends/resumes
    - Workload is mostly SELECTs that finish in 5 seconds or less (the hard timeout)
    - No CALL statements (not supported on interactive warehouses)
    - Selective queries (low share of partitions scanned)

  Requires access to SNOWFLAKE.ACCOUNT_USAGE (e.g. ACCOUNTADMIN or a role granted
  IMPORTED PRIVILEGES / the GOVERNANCE_VIEWER + USAGE_VIEWER database roles).
  ACCOUNT_USAGE views lag by up to ~3 hours; the window below excludes today.
*/

SET lookback_days = 30;

-- ASSUMPTION: interactive credits/hour as a fraction of standard Gen1 credits/hour for the
-- same size. 0.6 comes from a third-party pricing guide (XS: 0.6 vs 1). Confirm in Snowflake's
-- credit consumption table and adjust before using the cost columns.
SET interactive_rate_ratio = 0.6;

WITH daily_usage AS (
    -- Hours per day with compute running, from hourly metering
    SELECT
        warehouse_name,
        start_time::DATE                     AS usage_date,
        COUNT_IF(credits_used_compute > 0)   AS active_hours,
        SUM(credits_used_compute)            AS compute_credits
    FROM snowflake.account_usage.warehouse_metering_history
    WHERE start_time >= DATEADD(day, -$lookback_days, CURRENT_DATE())
      AND start_time <  CURRENT_DATE()
      AND warehouse_name <> 'CLOUD_SERVICES_ONLY'
    GROUP BY 1, 2
),

uptime AS (
    SELECT
        warehouse_name,
        COUNT(*)              AS days_used,
        AVG(active_hours)     AS avg_active_hours_per_day,
        MIN(active_hours)     AS min_active_hours_per_day,
        SUM(compute_credits)  AS total_compute_credits,
        AVG(compute_credits)  AS avg_credits_per_day
    FROM daily_usage
    WHERE active_hours > 0
    GROUP BY 1
),

resumes AS (
    -- Suspend/resume churn. If resume counts come back as 0 for warehouses you know resume,
    -- remove the event_state filter (event logging details vary).
    SELECT
        warehouse_name,
        COUNT_IF(event_name = 'RESUME_WAREHOUSE')  AS resume_events,
        COUNT_IF(event_name = 'SUSPEND_WAREHOUSE') AS suspend_events
    FROM snowflake.account_usage.warehouse_events_history
    WHERE timestamp >= DATEADD(day, -$lookback_days, CURRENT_DATE())
      AND timestamp <  CURRENT_DATE()
      AND event_state = 'COMPLETED'
    GROUP BY 1
),

query_profile AS (
    SELECT
        warehouse_name,
        MODE(warehouse_size)                                         AS typical_size,
        COUNT(*)                                                     AS total_queries,
        COUNT_IF(query_type = 'SELECT') / NULLIF(COUNT(*), 0)        AS pct_select,
        COUNT_IF(total_elapsed_time <= 5000) / NULLIF(COUNT(*), 0)   AS pct_under_5s,
        APPROX_PERCENTILE(total_elapsed_time, 0.50) / 1000           AS p50_elapsed_sec,
        APPROX_PERCENTILE(total_elapsed_time, 0.95) / 1000           AS p95_elapsed_sec,
        COUNT_IF(query_type = 'CALL')                                AS call_statements,
        AVG(IFF(partitions_total > 0,
                partitions_scanned / partitions_total, NULL))        AS avg_pct_partitions_scanned,
        AVG(queued_overload_time) / 1000                             AS avg_queued_overload_sec
    FROM snowflake.account_usage.query_history
    WHERE start_time >= DATEADD(day, -$lookback_days, CURRENT_DATE())
      AND start_time <  CURRENT_DATE()
      AND warehouse_name IS NOT NULL
      AND execution_status = 'SUCCESS'
    GROUP BY 1
),

combined AS (
    SELECT
        u.warehouse_name,
        q.typical_size,
        u.days_used,
        u.avg_active_hours_per_day,
        u.min_active_hours_per_day,
        COALESCE(r.resume_events, 0) / NULLIF(u.days_used, 0)                    AS resumes_per_day,
        q.total_queries,
        q.total_queries / NULLIF(u.avg_active_hours_per_day * u.days_used, 0)   AS queries_per_active_hour,
        q.pct_select,
        q.pct_under_5s,
        q.p50_elapsed_sec,
        q.p95_elapsed_sec,
        q.call_statements,
        q.avg_pct_partitions_scanned,
        q.avg_queued_overload_sec,
        u.avg_credits_per_day,
        -- Standard Gen1 credits/hour by size, used only for the interactive estimate
        CASE q.typical_size
            WHEN 'X-Small'  THEN 1   WHEN 'Small'    THEN 2
            WHEN 'Medium'   THEN 4   WHEN 'Large'    THEN 8
            WHEN 'X-Large'  THEN 16  WHEN '2X-Large' THEN 32
            WHEN '3X-Large' THEN 64  WHEN '4X-Large' THEN 128
        END                                                                     AS std_credits_per_hour
    FROM uptime u
    LEFT JOIN resumes       r ON r.warehouse_name = u.warehouse_name
    LEFT JOIN query_profile q ON q.warehouse_name = u.warehouse_name
)

SELECT
    warehouse_name,
    typical_size,
    days_used,
    ROUND(avg_active_hours_per_day, 1)              AS avg_active_hrs_per_day,
    min_active_hours_per_day                        AS min_active_hrs_per_day,
    ROUND(resumes_per_day, 1)                       AS resumes_per_day,
    total_queries,
    ROUND(queries_per_active_hour, 0)               AS queries_per_active_hr,
    ROUND(pct_select * 100, 1)                      AS pct_select,
    ROUND(pct_under_5s * 100, 1)                    AS pct_under_5s,
    ROUND(p50_elapsed_sec, 2)                       AS p50_sec,
    ROUND(p95_elapsed_sec, 2)                       AS p95_sec,
    call_statements,
    ROUND(avg_pct_partitions_scanned * 100, 1)      AS avg_pct_partitions_scanned,
    ROUND(avg_queued_overload_sec, 2)               AS avg_queue_sec,
    ROUND(avg_credits_per_day, 1)                   AS current_credits_per_day,
    -- Rough: one cluster, running 24h, at the assumed rate ratio. Excludes fallback and refresh warehouses.
    ROUND(24 * std_credits_per_hour * $interactive_rate_ratio, 1) AS est_interactive_credits_per_day,

    CASE
        WHEN avg_active_hours_per_day >= 18
         AND resumes_per_day <= 2
         AND pct_select >= 0.90
         AND pct_under_5s >= 0.95
         AND call_statements = 0
            THEN 'STRONG CANDIDATE'
        WHEN avg_active_hours_per_day >= 12
         AND pct_select >= 0.80
         AND pct_under_5s >= 0.90
            THEN 'POSSIBLE - REVIEW'
        ELSE 'NOT A FIT'
    END AS verdict,

    ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
        IFF(avg_active_hours_per_day < 12,  'idle much of the day (1-hr min billing per resume)', NULL),
        IFF(resumes_per_day > 2,            'frequent suspend/resume (cache resets)', NULL),
        IFF(pct_select < 0.80,              'significant non-SELECT work (DML/ETL)', NULL),
        IFF(pct_under_5s < 0.90,            'many queries exceed 5s timeout (fallback cost)', NULL),
        IFF(call_statements > 0,            'uses CALL (not supported)', NULL),
        IFF(avg_pct_partitions_scanned > 0.50, 'queries scan most partitions (not selective)', NULL),
        IFF(24 * std_credits_per_hour * $interactive_rate_ratio > avg_credits_per_day,
                                            'estimated interactive cost exceeds current', NULL)
    ), '; ') AS concerns

FROM combined
ORDER BY
    CASE verdict WHEN 'STRONG CANDIDATE' THEN 1 WHEN 'POSSIBLE - REVIEW' THEN 2 ELSE 3 END,
    avg_active_hours_per_day DESC;
