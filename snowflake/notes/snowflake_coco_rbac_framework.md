# Snowflake CoCo RBAC Integration & Security Framework

This document outlines the step-by-step strategy and SQL implementations required to integrate Snowflake CoCo into a Role-Based Access Control (RBAC) architecture, layer on Row-Level Security (RLS) and Column-Level Masking (CLM), and set up governance and cost controls.

---

## 1. Architectural Overview

Snowflake CoCo natively inherits and respects the existing permissions of the active session user. Rather than granting privileges directly to CoCo, security administrators configure multi-layered functional roles and governance guardrails.

| Layer | Controlled By | Purpose |
| :--- | :--- | :--- |
| **1. Application Access** | `CORTEX_MODEL_ROLE_ALL` | Determines if a user can wake up/query CoCo. |
| **2. Operations & DDL** | User's standard functional role | Restricts what data CoCo can read or write. |
| **3. Governance** | `GOVERNANCE_VIEWER` roles | Enables CoCo to scan system history/lineage. |
| **4. Cost Guardrails** | Budget / Token Parameters | Limits financial exposure from loop workflows. |

---

## 2. Core RBAC Setup Script

This script creates a dedicated `DATA_ENGINEER_COCO_ROLE`, grants it the necessary database and Cortex model access, and applies Resource Monitors to control costs.

```sql
-- =====================================================================
-- STEP 1: Create the Dedicated Functional Role (Run as SECURITYADMIN)
-- =====================================================================
USE ROLE SECURITYADMIN;

CREATE ROLE IF NOT EXISTS DATA_ENGINEER_COCO_ROLE;

-- Assign the new role to a user (replace with actual username)
GRANT ROLE DATA_ENGINEER_COCO_ROLE TO USER JSMITH;


-- =====================================================================
-- STEP 2: Grant Cortex and Application Privileges (Run as ACCOUNTADMIN)
-- =====================================================================
USE ROLE ACCOUNTADMIN;

-- Allow the role to use Snowflake Cortex AI and CoCo capabilities
GRANT APPLICATION ROLE SNOWFLAKE.CORTEX_MODEL_ROLE_ALL TO ROLE DATA_ENGINEER_COCO_ROLE;


-- =====================================================================
-- STEP 3: Configure Database & Schema Privileges (Run as SYSADMIN)
-- =====================================================================
USE ROLE SYSADMIN;

-- Grant warehouse usage for execution credits
GRANT USAGE ON WAREHOUSE dev_wh TO ROLE DATA_ENGINEER_COCO_ROLE;

-- Grant read and write access to the analytics environment
GRANT USAGE ON DATABASE analytics_db TO ROLE DATA_ENGINEER_COCO_ROLE;
GRANT USAGE ON SCHEMA analytics_db.reporting TO ROLE DATA_ENGINEER_COCO_ROLE;

-- CoCo needs table-level DDL rights to build pipelines on the user's behalf
GRANT CREATE TABLE, CREATE VIEW ON SCHEMA analytics_db.reporting TO ROLE DATA_ENGINEER_COCO_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA analytics_db.reporting TO ROLE DATA_ENGINEER_COCO_ROLE;


-- =====================================================================
-- STEP 4: Establish Cost Guardrails & Limits (Run as ACCOUNTADMIN)
-- =====================================================================
USE ROLE ACCOUNTADMIN;

-- Create a strict resource monitor to prevent budget overruns from LLM loops
CREATE RESOURCE MONITOR IF NOT EXISTS coco_dev_guardrail
  WITH CREDIT_QUOTA = 50 -- Set your monthly budget threshold in credits
  FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS 
    ON 80 PERCENT DO NOTIFY -- Alert when hitting 80% of budget
    ON 100 PERCENT DO SUSPEND; -- Suspend warehouse activity at 100%

-- Assign the resource monitor directly to the warehouse used by this role
ALTER WAREHOUSE dev_wh SET RESOURCE_MONITOR = coco_dev_guardrail;
```

---

## 3. Row-Level Security (RLS) & Governance Expansion

This section layers on Row-Level Security to restrict CoCo's data visibility geographically, alongside a dedicated Data Steward role to handle cross-database metadata audits and object lineage.

```sql
-- =====================================================================
-- STEP 1: Implement Row-Level Security (Run as EXEMPT_ADMIN or SECURITYADMIN)
-- =====================================================================
USE ROLE SECURITYADMIN;
USE DATABASE analytics_db;
USE SCHEMA reporting;

-- Create an entitlement table mapping roles to regions
CREATE OR REPLACE TABLE reporting.regional_entitlements (
  role_name   VARCHAR,
  region_id   VARCHAR
);

-- Populate table: Let our new Data Engineer role only see NA (North America) rows
INSERT INTO reporting.regional_entitlements (role_name, region_id) 
VALUES ('DATA_ENGINEER_COCO_ROLE', 'NA');

-- Create the Row Access Policy
-- CoCo strictly inherits session rules; if the user's role can't see the row, CoCo can't either
CREATE OR REPLACE ROW ACCESS POLICY regional_policy
  AS (current_region VARCHAR) RETURNS BOOLEAN ->
    EXISTS (
      SELECT 1 FROM reporting.regional_entitlements
      WHERE role_name = CURRENT_ROLE()
        AND region_id = current_region
    )
    OR CURRENT_ROLE() = 'ACCOUNTADMIN' -- Global fallback
;

-- Apply the policy to a sensitive target table
ALTER TABLE reporting.customer_transactions 
  ADD ROW ACCESS POLICY regional_policy ON (transaction_region);


-- =====================================================================
-- STEP 2: Configure the Data Steward Role (Run as SECURITYADMIN)
-- =====================================================================
USE ROLE SECURITYADMIN;

CREATE ROLE IF NOT EXISTS DATA_STEWARD_COCO_ROLE;

-- Assign to your governance lead
GRANT ROLE DATA_STEWARD_COCO_ROLE TO USER AMILLER;


-- =====================================================================
-- STEP 3: Elevate Governance & Lineage Access (Run as ACCOUNTADMIN)
-- =====================================================================
USE ROLE ACCOUNTADMIN;

-- Grant standard base model rights so the Steward can interface with CoCo
GRANT APPLICATION ROLE SNOWFLAKE.CORTEX_MODEL_ROLE_ALL TO ROLE DATA_STEWARD_COCO_ROLE;

-- Grant system metadata rights so CoCo can build lineage graphs and scan access history
GRANT DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER TO ROLE DATA_STEWARD_COCO_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.OBJECT_VIEWER TO ROLE DATA_STEWARD_COCO_ROLE;

-- Provide warehouse access for running these metadata lookups
GRANT USAGE ON WAREHOUSE governance_wh TO ROLE DATA_STEWARD_COCO_ROLE;
```

---

## 4. Column-Level Masking (CLM)

This script creates reusable Column-Level Masking Policies to protect sensitive customer identifiers (emails and identification numbers) at the storage level before the LLM can ingest them.

```sql
-- =====================================================================
-- STEP 1: Create the Masking Policy (Run as SECURITYADMIN)
-- =====================================================================
USE ROLE SECURITYADMIN;
USE DATABASE analytics_db;
USE SCHEMA reporting;

-- Create a policy that fully redacts data for the Data Engineer,
-- but allows unmasked access for specialized roles (like accounting)
CREATE OR REPLACE MASKING POLICY email_mask_policy 
  AS (val VARCHAR) RETURNS VARCHAR ->
    CASE
      WHEN CURRENT_ROLE() IN ('ACCOUNTING_ROLE', 'ACCOUNTADMIN') THEN val
      ELSE '*********' -- What the Data Engineer and CoCo will see
    END;

-- Create a partial masking policy for SSN or identification numbers
CREATE OR REPLACE MASKING POLICY ssn_mask_policy 
  AS (val VARCHAR) RETURNS VARCHAR ->
    CASE
      WHEN CURRENT_ROLE() IN ('HR_ROLE', 'ACCOUNTADMIN') THEN val
      ELSE CONCAT('XXX-XX-', RIGHT(val, 4)) -- Masks all but the last 4 digits
    END;


-- =====================================================================
-- STEP 2: Apply the Policies to the Target Table (Run as ALTER privilege holder)
-- =====================================================================
-- Apply masking directly to the sensitive columns
ALTER TABLE reporting.customer_transactions 
  MODIFY COLUMN customer_email SET MASKING POLICY email_mask_policy;

ALTER TABLE reporting.customer_transactions 
  MODIFY COLUMN customer_ssn SET MASKING POLICY ssn_mask_policy;
```

---

## 5. Verification Framework

To verify that all integrated security policies function seamlessly together, run a test query under the targeted role context:

```sql
USE ROLE DATA_ENGINEER_COCO_ROLE;
USE WAREHOUSE dev_wh;

-- 1. Verify Cortex application availability
SELECT SNOWFLAKE.CORTEX.COMPLETE('llama3-70b', 'Verify RBAC role integration status.');

-- 2. Test RLS and CLM impact on CoCo execution contexts
SELECT transaction_region, customer_email, customer_ssn 
FROM analytics_db.reporting.customer_transactions 
LIMIT 5;
```
*Expected Behavior:* The user (and CoCo) will only see transactions where `transaction_region = 'NA'`, emails will be completely redacted (`*********`), and SSNs will mask all but the trailing four digits (`XXX-XX-1234`).
