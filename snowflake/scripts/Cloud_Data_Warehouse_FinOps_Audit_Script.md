# 🛑 FinOps Audit Playbook: Cloud Data Warehouse Anomaly Detection

This playbook establishes a production-grade monitoring framework to identify, isolate, and remediate systemic cloud infrastructure waste. It target the three primary drivers of unnecessary warehouse costs: runaway queries, idle compute time, and unmanaged warehouse scaling.

---

## 💻 1. Automated Diagnostic Scripts (Snowflake Dialect)

Run these queries inside your metadata tracking database (or via an automated orchestration tool) to pull anomalous infrastructure usage patterns over a rolling lookback window.

### Check 1: Runaway Queries (Execution > 30 Minutes)
*Locates inefficient execution, missing join predicates, or broken recursive loops.*

```sql
SELECT 
    query_id,
    warehouse_name,
    warehouse_size,
    user_name,
    ROUND(execution_time / 1000 / 60, 2) AS execution_time_minutes,
    ROUND(total_elapsed_time / 1000 / 60, 2) AS total_elapsed_minutes,
    SUBSTRING(query_text, 1, 150) AS truncated_query_text
FROM snowflake.account_usage.query_history
WHERE start_time >= DATEADD(day, -1, CURRENT_TIMESTAMP()) 
  AND execution_time > 1800000 -- Threshold: 30 minutes in milliseconds
  AND execution_status = 'SUCCESS'
ORDER BY execution_time DESC;
```

### Check 2: Idle Compute Waste (Active Warehouses with Zero Queries)
*Identifies warehouses remaining online and burning credits without running workloads due to poor auto-suspend profiles.*

```sql
WITH warehouse_hourly_usage AS (
    SELECT 
        warehouse_name,
        DATE_TRUNC('hour', start_time) AS usage_hour,
        SUM(credits_used) AS total_credits_spent
    FROM snowflake.account_usage.warehouse_metering_history
    WHERE start_time >= DATEADD(day, -7, CURRENT_TIMESTAMP()) 
    GROUP BY 1, 2
),
warehouse_hourly_execution AS (
    SELECT 
        warehouse_name,
        DATE_TRUNC('hour', start_time) AS execution_hour,
        COUNT(query_id) AS total_queries_executed,
        SUM(execution_time) AS total_active_execution_ms
    FROM snowflake.account_usage.query_history
    WHERE start_time >= DATEADD(day, -7, CURRENT_TIMESTAMP())
    GROUP BY 1, 2
)
SELECT 
    u.warehouse_name,
    u.usage_hour,
    ROUND(u.total_credits_spent, 2) AS credits_spent,
    COALESCE(e.total_queries_executed, 0) AS queries_executed,
    ROUND(COALESCE(e.total_active_execution_ms, 0) / 1000 / 60, 2) AS active_execution_minutes
FROM warehouse_hourly_usage u
LEFT JOIN warehouse_hourly_execution e 
    ON u.warehouse_name = e.warehouse_name 
   AND u.usage_hour = e.execution_hour
WHERE e.total_queries_executed IS NULL -- Spent credits but ran 0 queries
   OR (e.total_active_execution_ms / 1000 / 60) < 5 -- Active for an hour but ran queries for < 5 mins
ORDER BY credits_spent DESC;
```

### Check 3: Unauthorized Warehouse Size Alterations
*Tracks ad-hoc manual size scaling changes that cause sharp, unbudgeted spend spikes.*

```sql
SELECT 
    timestamp AS event_time,
    user_name,
    role_name,
    SUBSTRING(query_text, 1, 200) AS DDL_command
FROM snowflake.account_usage.query_history
WHERE start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP()) 
  AND query_type = 'ALTER_WAREHOUSE'
  AND (ILIKE(query_text, '%SET WAREHOUSE_SIZE%') OR ILIKE(query_text, '%MAX_CLUSTER_COUNT%'))
ORDER BY timestamp DESC;
```

---

## 🛠️ 2. Tactical Remediation Playbook

When an anomaly triggers an alert, apply these production guardrails to stabilize and optimize infrastructure spending permanently.

### Issue 1: Runaway Queries Fix
*   **Root Cause:** Sub-optimal code patterns or missing filters.
*   **Remediation:** Enforce a hard statement execution timeout limit directly on the warehouse profile to automatically kill hanging processes.
```sql
ALTER WAREHOUSE <warehouse_name> SET STATEMENT_TIMEOUT_IN_SECONDS = 1800; -- Auto-kill at 30 mins
```

### Issue 2: Idle Compute Waste Fix
*   **Root Cause:** Auto-suspend properties set too loose (e.g., 10+ minutes) or entirely disabled (`NULL`).
*   **Remediation:** Configure tight auto-suspend properties to drop clusters out of memory shortly after workloads conclude.
```sql
ALTER WAREHOUSE <warehouse_name> SET AUTO_SUSPEND = 60; -- Auto-suspend after 1 minute of silence
```

### Issue 3: Size Scaling Spike Fix
*   **Root Cause:** Manual, loose user manipulation of base cluster topology size.
*   **Remediation:** Strip down individual modification permissions and force all infrastructure state provisioning through managed pipelines.
```sql
-- Revoke manual alteration capabilities from standard roles
REVOKE MODIFY ON WAREHOUSE <warehouse_name> FROM ROLE analyst_role;
```
