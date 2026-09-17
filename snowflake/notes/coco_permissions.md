### Snowflake CoCo (Cortex Code) Configuration & Cost Governance Guide

This guide details the administrative setup required to enable Snowflake CoCo for **ROLE_HR**, configure session-level secondary role aggregation, audit generated query activities, and establish strict compute isolation and budget safety controls. 

### 1. Core Feature Access Setup (RBAC)

Execute the following commands using an account role holding the MANAGE GRANTS privilege to enable core CoCo and LLM capabilities for the targeted HR role. 

sql

-- Switch to administrative authorization
USE ROLE SECURITYADMIN;

-- Grant core CoCo assistant workspace permissions
GRANT DATABASE ROLE SNOWFLAKE.COPILOT_USER TO ROLE ROLE_HR;

-- Grant least-privilege agent workflow permissions 
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER TO ROLE ROLE_HR;

-- Verify applied permissions
SHOW GRANTS TO ROLE ROLE_HR;

Use code with caution.

### 2. Interactive Workspace Configuration (Secondary Roles)

CoCo reads from user profile properties at session initiation. To allow CoCo to securely evaluate permissions extended across an HR analyst's secondary role pool during Snowsight operations, secondary roles must be set globally. 

CoCo InterfaceSecondary Roles SupportOperational Impact & Context
****CoCo in Snowsight****
**Fully Supported**Aggregates ROLE_HR with active secondary privileges when DEFAULT_SECONDARY_ROLES = ('ALL').
****CoCo CLI (Desktop)****
**Not Supported**Token ROLE_RESTRICTION overrides settings. Forces single primary role isolation.

### Enable Secondary Role Aggregation

sql

USE ROLE USERADMIN;

-- Alter targeted user profiles to aggregate role pools automatically
ALTER USER hr_username_here SET DEFAULT_SECONDARY_ROLES = ('ALL');

Use code with caution.

### 3. Compute Isolation & Cost Governance Guardrails

To prevent runaway compute charges, unoptimized analytical processing, or deep-table scan costs from conversational AI queries, ROLE_HR is restricted to an isolated, right-sized virtual warehouse wrapped in a hardware resource monitor contract. 

 [](https://mail.google.com/mail/?extsrc=sync&client=h&plid=ACUX6DPykoftDokybtJXGwxN76PPxzJ0XkNi_cQ)

### A. Create Isolated Interactive Compute

sql

USE ROLE SYSADMIN;

-- Provision a highly responsive, cost-capped small warehouse
CREATE OR REPLACE WAREHOUSE WH_HR_INTERACTIVE
  WAREHOUSE_SIZE = 'SMALL'                    -- Maximum credit consumption threshold per hour
  AUTO_SUSPEND = 60                           -- Suspends after 1 minute of complete inactivity to prevent leakage [0.7.3]
  AUTO_RESUME = TRUE                          -- Automatic spin up upon user interface entry
  STATEMENT_TIMEOUT_IN_SECONDS = 5            -- Kills hanging or massive scanning queries at 5 seconds
  COMMENT = 'Dedicated warehouse pool for ROLE_HR and CoCo interactive sessions';

-- Authorize usage
GRANT USAGE ON WAREHOUSE WH_HR_INTERACTIVE TO ROLE ROLE_HR;

Use code with caution.

### B. Bind Compute Context to Users by Default

sql

USE ROLE USERADMIN;

-- Lock default execution pathways to the guarded warehouse pool
ALTER USER hr_username_here SET DEFAULT_WAREHOUSE = 'WH_HR_INTERACTIVE';

Use code with caution.

### C. Enforce Hard Monthly Budget Monitors

sql

USE ROLE ACCOUNTADMIN;

-- Define a strict credit enforcement monitor resetting monthly [0.7.3]
CREATE OR REPLACE RESOURCE MONITOR RM_HR_INTERACTIVE
  CREDIT_QUOTA = 100                          -- Absolute monthly credit allocation pool
  FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 80 PERCENT DO NOTIFY                   -- Broadcast warning to platform administrators
    ON 100 PERCENT DO SUSPEND;                -- Gracefully blocks new queries while letting active jobs complete [0.7.3]

-- Apply cost protection to the dedicated HR warehouse
ALTER WAREHOUSE WH_HR_INTERACTIVE SET RESOURCE_MONITOR = RM_HR_INTERACTIVE;

Use code with caution.

### D. Enforce Cross-Warehouse Role-Level Guardrails

sql

USE ROLE SECURITYADMIN;

-- Global role timeout policy to guarantee strict execution bounds regardless of selected warehouse
ALTER ROLE ROLE_HR SET STATEMENT_TIMEOUT_IN_SECONDS = 30;

Use code with caution.

### 4. Query Telemetry & Security Auditing

Use this audit script to monitor every SQL query executed by conversational agents or interface users inside **DB_HR**. This query explicitly captures client tracking parameters to filter out internal system actions. 

sql

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

Use code with caution.
