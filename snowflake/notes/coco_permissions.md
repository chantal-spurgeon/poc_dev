# Snowflake CoCo (Cortex Code) Configuration & Cost Governance Guide

This guide details the administrative setup required to enable Snowflake CoCo for **`ROLE_HR`**, configure session-level secondary role aggregation, audit generated query activities, and establish strict compute isolation and budget safety controls.

---

## 1. Core Feature Access Setup (RBAC)
Execute the following commands using an account role holding the `MANAGE GRANTS` privilege to enable core CoCo and LLM capabilities for the targeted HR role.

```sql
-- Switch to administrative authorization
USE ROLE SECURITYADMIN;

-- Grant core CoCo assistant workspace permissions
GRANT DATABASE ROLE SNOWFLAKE.COPILOT_USER TO ROLE ROLE_HR;

-- Grant least-privilege agent workflow permissions 
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER TO ROLE ROLE_HR;

-- Verify applied permissions
SHOW GRANTS TO ROLE ROLE_HR;
```

---

## 2. Interactive Workspace Configuration (Secondary Roles)
CoCo reads from user profile properties at session initiation. To allow CoCo to securely evaluate permissions extended across an HR analyst's secondary role pool during Snowsight operations, secondary roles must be set globally.

| CoCo Interface | Secondary Roles Support | Operational Impact & Context |
| :--- | :--- | :--- |
| **CoCo in Snowsight** | **Fully Supported** | Aggregates `ROLE_HR` with active secondary privileges when `DEFAULT_SECONDARY_ROLES = ('ALL')`. |
| **CoCo CLI (Desktop)** | **Not Supported** | Token `ROLE_RESTRICTION` overrides settings. Forces single primary role isolation. |

### Enable Secondary Role Aggregation
```sql
USE ROLE USERADMIN;

-- Alter targeted user profiles to aggregate role pools automatically
ALTER USER hr_username_here SET DEFAULT_SECONDARY_ROLES = ('ALL');
```

---

## 3. Compute Isolation & Cost Governance Guardrails
To prevent runaway compute charges, unoptimized analytical processing, or deep-table scan costs from conversational AI queries, `ROLE_HR` is restricted to an isolated, right-sized virtual warehouse wrapped in a hardware resource monitor contract.

### A. Create Isolated Interactive Compute
```sql
USE ROLE SYSADMIN;

-- Provision a highly responsive, cost-capped small warehouse
CREATE OR REPLACE WAREHOUSE WH_HR_INTERACTIVE
  WAREHOUSE_SIZE = 'SMALL'                    -- Maximum credit consumption threshold per hour
  AUTO_SUSPEND = 60                           -- Suspends after 1 minute of complete inactivity to prevent leakage
  AUTO_RESUME = TRUE                          -- Automatic spin up upon user interface entry
  STATEMENT_TIMEOUT_IN_SECONDS = 5            -- Kills hanging or massive scanning queries at 5 seconds
  COMMENT = 'Dedicated warehouse pool for ROLE_HR and CoCo interactive sessions';

-- Authorize usage
GRANT USAGE ON WAREHOUSE WH_HR_INTERACTIVE TO ROLE ROLE_HR;
```

### B. Bind Compute Context to Users by Default
```sql
USE ROLE USERADMIN;

-- Lock default execution pathways to the guarded warehouse pool
ALTER USER hr_username_here SET DEFAULT_WAREHOUSE = 'WH_HR_INTERACTIVE';
```

### C. Enforce Hard Monthly Budget Monitors
```sql
USE ROLE ACCOUNTADMIN;

-- Define a strict credit enforcement monitor resetting monthly
CREATE OR REPLACE RESOURCE MONITOR RM_HR_INTERACTIVE
  CREDIT_QUOTA = 100                          -- Absolute monthly credit allocation pool
  FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 80 PERCENT DO NOTIFY                   -- Broadcast warning to platform administrators
    ON 100 PERCENT DO SUSPEND;                -- Gracefully blocks new queries while letting active jobs complete

-- Apply cost protection to the dedicated HR warehouse
ALTER WAREHOUSE WH_HR_INTERACTIVE SET RESOURCE_MONITOR = RM_HR_INTERACTIVE;
```

### D. Enforce Cross-Warehouse Role-Level Guardrails
```sql
USE ROLE SECURITYADMIN;

-- Global role timeout policy to guarantee strict execution bounds regardless of selected warehouse
ALTER ROLE ROLE_HR SET STATEMENT_TIMEOUT_IN_SECONDS = 30;
```

---

## 4. Query Telemetry & Security Auditing
Use this audit script to monitor every SQL query executed by conversational agents or interface users inside **`DB_HR`**. This query explicitly captures client tracking parameters to filter out internal system actions.

```sql
USE ROLE AUDITADMIN;

SELECT 
    query_id,
    user_name,
    role_name,
    warehouse_name,
    execution_status,
    total_elapsed_time / 1000 AS elapsed_seconds,
    credits_used_cloud_services,
    query_text,
    start_time
FROM snowflake.account_usage.query_history
WHERE database_name = 'DB_HR'
  AND start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  -- Filters for interactive sessions, background functions, or programmatic client interfaces
  AND (
       LOWER(client_environment:APPLICATION::STRING) LIKE '%cortex%'
       OR LOWER(client_environment:APPLICATION::STRING) LIKE '%copilot%'
       OR role_name = 'ROLE_HR'
  )
ORDER BY start_time DESC;
```

---

## 5. Automated Timeout Alerting Mechanism
To guarantee that engineering teams are notified immediately when a CoCo or user-driven session triggers a timeout policy fault, a native Snowflake Alert can be scheduled to run in the background.

### Prerequisites (Execute as ACCOUNTADMIN)
```sql
USE ROLE ACCOUNTADMIN;

-- 1. Create a platform notification integration for email delivery
CREATE OR REPLACE NOTIFICATION INTEGRATION NOTIFY_DATA_PLATFORM_TEAM
  TYPE = EMAIL
  ENABLED = TRUE
  ALLOWED_RECIPIENTS = ('dataplatform@yourcompany.com'); -- Replace with your actual team distribution list

-- 2. Grant execution rights to the managing role (e.g., SYSADMIN)
GRANT USAGE ON INTEGRATION NOTIFY_DATA_PLATFORM_TEAM TO ROLE SYSADMIN;
```

### Create the Snowflake Alert
```sql
USE ROLE SYSADMIN;
USE DATABASE DB_HR;
USE SCHEMA PUBLIC;

-- Create an alert that evaluates the telemetry log every 1 hour
CREATE OR REPLACE ALERT ALERT_HR_COCO_TIMEOUTS
  WAREHOUSE = WH_HR_INTERACTIVE
  SCHEDULE = 'USING CRON 0 * * * * UTC' -- Evaluates at the top of every hour
  IF (EXISTS (
      SELECT 1
      FROM snowflake.account_usage.query_history
      WHERE role_name = 'ROLE_HR'
        AND execution_status = 'FAIL_TIMEOUT'
        AND end_time >= DATEADD('hour', -1, CURRENT_TIMESTAMP())
  ))
  THEN 
    CALL SYSTEM\$SEND_EMAIL(
        'NOTIFY_DATA_PLATFORM_TEAM',
        'dataplatform@yourcompany.com',
        'Alert: Snowflake ROLE_HR Query Timeout Detected',
        'The Snowflake monitoring agent has detected one or more queries executed by ROLE_HR that failed due to a STATEMENT TIMEOUT error within the past hour. Please review snowflake.account_usage.query_history to troubleshoot potential infinite loops, unoptimized table scans, or runaway CoCo operations.'
    );

-- Crucial: Newly created alerts are suspended by default. You must resume it to start execution.
ALTER ALERT ALERT_HR_COCO_TIMEOUTS RESUME;
```
