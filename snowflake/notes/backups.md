# Snowflake Database Backup, RBAC, and Disaster Recovery Blueprint

## Feature Availability Grid

| Feature | Standard | Enterprise | Business Critical (or higher) |
| :--- | :---: | :---: | :---: |
| **CREATE BACKUP SET / POLICY** | Yes | Yes | Yes |
| **Automated & Scheduled Backups** | Yes | Yes | Yes |
| **Point-in-Time Database Restores** | Yes | Yes | Yes |
| **Retention Lock (`WITH RETENTION LOCK`)** | No | No | Yes |
| **Legal Holds (`ADD LEGAL HOLD`)** | No | No | Yes |

*Note for Enterprise Edition:* The `WITH RETENTION LOCK` and legal hold options require Business Critical edition or higher. Standard and Enterprise support automated scheduling, standard retention policies, and disaster recovery restores without hardware-enforced immutability locks.

---

## 1. Setup Roles and Container Context

```sql
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;

CREATE DATABASE IF NOT EXISTS data_governance_db;
CREATE SCHEMA IF NOT EXISTS data_governance_db.backup_management;
USE SCHEMA data_governance_db.backup_management;
```

---

## 2. Create a Backup Policy (Enterprise Edition Compatible)

```sql
-- Standard rolling operational policy (e.g., every 12 hours, expires after 30 days)
CREATE OR REPLACE BACKUP POLICY operational_30day_policy
  EXPIRE_AFTER_DAYS = 30
  SCHEDULE = '720 MINUTE'
  COMMENT = 'Standard operational rolling backup for Enterprise edition';
```

---

## 3. Create the Backup Set

```sql
CREATE OR REPLACE BACKUP SET prod_db_compliance_backups
  FOR DATABASE production_sales_db
  WITH BACKUP POLICY operational_30day_policy;
  
-- Manually trigger an immediate backup snapshot
ALTER BACKUP SET prod_db_compliance_backups ADD BACKUP;
```

---

## 4. Role-Based Access Control (RBAC) Setup

```sql
-- Create a custom role for backup management
CREATE ROLE IF NOT EXISTS BACKUP_ADMIN_ROLE;

-- Grant usage and management privileges on the governance database/schema
GRANT USAGE ON DATABASE data_governance_db TO ROLE BACKUP_ADMIN_ROLE;
GRANT USAGE ON SCHEMA data_governance_db.backup_management TO ROLE BACKUP_ADMIN_ROLE;

-- Grant specific backup creation and management privileges
GRANT CREATE BACKUP POLICY ON SCHEMA data_governance_db.backup_management TO ROLE BACKUP_ADMIN_ROLE;
GRANT USAGE ON BACKUP POLICY operational_30day_policy TO ROLE BACKUP_ADMIN_ROLE;
GRANT MODIFY, USAGE ON BACKUP SET prod_db_compliance_backups TO ROLE BACKUP_ADMIN_ROLE;

-- Grant role to a designated user or admin group
GRANT ROLE BACKUP_ADMIN_ROLE TO ROLE SYSADMIN;
```

---

## 5. Monitor Your Backups

```sql
SHOW BACKUP POLICIES;
SHOW BACKUPS IN BACKUP SET prod_db_compliance_backups;

SELECT * 
FROM SNOWFLAKE.ACCOUNT_USAGE.BACKUP_OPERATION_HISTORY
ORDER BY START_TIME DESC;
```

---

## 6. Disaster Recovery (DR) Runbook Sequence

### Phase 1: Assess and Validate Failure
Verify the production database is unrecoverable or corrupted and identify the latest successful backup snapshot ID.

```sql
SHOW BACKUPS IN BACKUP SET prod_db_compliance_backups;
```

### Phase 2: Provision Isolated Recovery Target
Materialize a fully functional recovered database using the verified snapshot UUID.

```sql
CREATE DATABASE recovered_production_sales_db 
  FROM BACKUP SET prod_db_compliance_backups 
  IDENTIFIER '<insert-backup-uuid-here>';
```

### Phase 3: Validate Restored Data Integrity
Run verification queries on the restored database schema and row counts.

```sql
USE DATABASE recovered_production_sales_db;
SELECT COUNT(*) FROM critical_sales_table;
```

### Phase 4: Reassign Downstream Permissions
Grant necessary usage and select privileges on the newly recovered database to analytics and application roles.

```sql
GRANT USAGE ON DATABASE recovered_production_sales_db TO ROLE ANALYST_ROLE;
GRANT USAGE ON ALL SCHEMAS IN DATABASE recovered_production_sales_db TO ROLE ANALYST_ROLE;
GRANT SELECT ON ALL TABLES IN DATABASE recovered_production_sales_db TO ROLE ANALYST_ROLE;
```

### Phase 5: Production Cutover
Rename or drop the broken upstream database (if safe) and redirect application traffic or views to point to the recovered database instance.
```sql
-- Optional final rename once primary is deprecated
-- ALTER DATABASE production_sales_db RENAME TO corrupt_production_sales_db;
-- ALTER DATABASE recovered_production_sales_db RENAME TO production_sales_db;
```

---

## 7. Automated Monitoring via Snowflake Tasks

To ensure failures don't go unnoticed, set up a serverless Snowflake Task that scans the system metadata tables once a day. If any backup operation fails, it generates a critical system exception or pushes a notification via Snowflake's Notification Integration system.

```sql
-- Step A: Set up an Alerting Notification Integration (if pushing directly to Email/SNS/Slack)
-- CREATE OR REPLACE NOTIFICATION INTEGRATION backup_alert_email_int
--   TYPE = EMAIL
--   ENABLED = TRUE
--   ALLOWED_RECIPIENTS = ('dataops-team@yourcompany.com');

-- Step B: Create an automated system check Task
CREATE OR REPLACE TASK monitor_backup_health_task
  WAREHOUSE = COMPUTE_WH
  SCHEDULE = 'USING CRON 0 6 * * * UTC' -- Evaluates daily at 6:00 AM UTC (after nightly cycles)
AS
  DECLARE
    failed_backups INT;
  BEGIN
    -- Query metadata to check if any backup operations in the past 24 hours failed
    SELECT COUNT(*) 
    INTO :failed_backups
    FROM SNOWFLAKE.ACCOUNT_USAGE.BACKUP_OPERATION_HISTORY
    WHERE STATUS = 'FAILED'
      AND START_TIME >= DATEADD(day, -1, CURRENT_TIMESTAMP());

    -- Take action if failure count is greater than zero
    IF (failed_backups > 0) THEN
      -- Option 1: Raise a system failure error to trip monitoring tools like Datadog/PagerDuty
      SYSTEM\$LOG_ERROR('CRITICAL: One or more Snowflake Database backup operations failed in the last 24 hours!');
      
      -- Option 2: Send direct email alert using native integration (Uncomment if Integration Step A is configured)
      -- CALL SYSTEM\$SEND_EMAIL(
      --   'backup_alert_email_int',
      --   'dataops-team@yourcompany.com',
      --   'ALERT: Snowflake Database Backup Failure Detected',
      --   'Critical infrastructure notice: One or more database backup instances failed within the last 24 hours. Check SNOWFLAKE.ACCOUNT_USAGE.BACKUP_OPERATION_HISTORY.'
      -- );
    END IF;
  END;

-- Step C: Tasks are created suspended by default. Enable the monitoring automation.
ALTER TASK monitor_backup_health_task RESUME;
```
