# Snowflake Schema Drift Detection & Automated Alerting Guide

This document outlines the setup for a production-ready **Schema Drift Engine** within Snowflake. It captures daily architectural snapshots, compares them against a moving baseline, logs anomalies, and sends email alerts whenever changes are detected.

---

## 🏗️ 1. Core Architecture Setup
Run this block first to initialize the persistent logging structures and schema baseline tables.

```sql
-- Establish the monitoring schema boundaries
CREATE SCHEMA IF NOT EXISTS schema_monitoring;
USE SCHEMA schema_monitoring;

-- Stores historical schema snapshots to act as your moving baseline
CREATE TABLE IF NOT EXISTS schema_snapshots (
    snapshot_timestamp TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    table_catalog VARCHAR,
    table_schema VARCHAR,
    table_name VARCHAR,
    column_name VARCHAR,
    data_type VARCHAR,
    ordinal_position NUMBER,
    is_nullable VARCHAR
);

-- Persistent logging table for auditing drift anomalies over time
CREATE TABLE IF NOT EXISTS detected_schema_drift (
    detection_timestamp TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    table_schema VARCHAR,
    table_name VARCHAR,
    column_name VARCHAR,
    change_category VARCHAR, -- COLUMN_ADDED, COLUMN_DROPPED, DATA_TYPE_CHANGED
    details VARCHAR
);
```

---

## 📧 2. Notification Channel Configuration
This defines the communication channel Snowflake uses to route outbound emails.

> ⚠️ **Privilege Requirement:** This block must be executed by an `ACCOUNTADMIN` or a role with explicit `CREATE INTEGRATION` security rights.

```sql
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE NOTIFICATION INTEGRATION schema_drift_email_int
  TYPE = EMAIL
  ENABLED = TRUE
  ALLOWED_RECIPIENTS = ('data_team_alerts@yourcompany.com'); -- 👈 Replace with your distribution group
```

---

## ⚙️ 3. The Automated Drift Engine (Task)
This automated task runs daily on a cron schedule, executing an internal metadata check to match the current database state against the newest historical records.

```sql
CREATE OR REPLACE TASK schema_monitoring.daily_schema_drift_check
    WAREHOUSE = my_monitoring_warehouse  -- 👈 Replace with your virtual warehouse name
    SCHEDULE = 'USING CRON 0 6 * * * UTC' -- Runs every day at 06:00 AM UTC
AS
DECLARE
    drift_count INTEGER DEFAULT 0;
    email_subject VARCHAR;
    email_body VARCHAR;
BEGIN
    -- 1. Snapshot the current schema state into a transient work table
    CREATE OR REPLACE TEMPORARY TABLE schema_monitoring.current_schema_state AS
    SELECT 
        CURRENT_TIMESTAMP() as snapshot_timestamp,
        table_catalog, table_schema, table_name, column_name, data_type, ordinal_position, is_nullable
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE table_schema NOT IN ('INFORMATION_SCHEMA', 'SCHEMA_MONITORING') 
      AND table_catalog = CURRENT_DATABASE();

    -- 2. Identify structural delta additions, drops, or updates
    CREATE OR REPLACE TEMPORARY TABLE schema_monitoring.detected_drift_summary AS
    WITH previous_baseline AS (
        SELECT * FROM schema_monitoring.schema_snapshots
        QUALIFY ROW_NUMBER() OVER (PARTITION BY table_schema, table_name, column_name ORDER BY snapshot_timestamp DESC) = 1
    )
    SELECT cur.table_schema, cur.table_name, cur.column_name, 'COLUMN_ADDED' AS change_category,
           'Column ' || cur.column_name || ' was added to ' || cur.table_schema || '.' || cur.table_name || ' with type ' || cur.data_type AS details
    FROM schema_monitoring.current_schema_state cur
    LEFT JOIN previous_baseline pre ON cur.table_schema = pre.table_schema AND cur.table_name = pre.table_name AND cur.column_name = pre.column_name
    WHERE pre.column_name IS NULL
    UNION ALL
    SELECT pre.table_schema, pre.table_name, pre.column_name, 'COLUMN_DROPPED' AS change_category,
           'Column ' || pre.column_name || ' was dropped from ' || pre.table_schema || '.' || pre.table_name AS details
    FROM previous_baseline pre
    LEFT JOIN schema_monitoring.current_schema_state cur ON pre.table_schema = cur.table_schema AND pre.table_name = cur.table_name AND pre.column_name = cur.column_name
    WHERE cur.column_name IS NULL
    UNION ALL
    SELECT cur.table_schema, cur.table_name, cur.column_name, 'DATA_TYPE_CHANGED' AS change_category,
           'Column ' || cur.column_name || ' type changed from ' || pre.data_type || ' to ' || cur.data_type AS details
    FROM schema_monitoring.current_schema_state cur
    JOIN previous_baseline pre ON cur.table_schema = pre.table_schema AND cur.table_name = pre.table_name AND cur.column_name = pre.column_name
    WHERE cur.data_type != pre.data_type;

    -- 3. Log any true structural drift found into persistent logs
    INSERT INTO schema_monitoring.detected_schema_drift (table_schema, table_name, column_name, change_category, details)
    SELECT table_schema, table_name, column_name, change_category, details FROM schema_monitoring.detected_drift_summary;

    -- 4. Advance baseline data to current point-in-time state
    INSERT INTO schema_monitoring.schema_snapshots (snapshot_timestamp, table_catalog, table_schema, table_name, column_name, data_type, ordinal_position, is_nullable)
    SELECT snapshot_timestamp, table_catalog, table_schema, table_name, column_name, data_type, ordinal_position, is_nullable FROM schema_monitoring.current_schema_state;

    -- 5. Evaluate if alerts need to be fired
    SELECT COUNT(*) INTO :drift_count FROM schema_monitoring.detected_drift_summary;
    
    IF (:drift_count > 0) THEN
        email_subject := '⚠️ Snowflake Schema Drift Alert: ' || :drift_count || ' Change(s) Detected in ' || CURRENT_DATABASE();
        
        email_body := '<h2>Snowflake Automated Schema Monitor</h2>' ||
                      '<p>The daily database audit discovered architectural changes. High-level summaries below:</p>' ||
                      '<table border="1" cellpadding="5" style="border-collapse:collapse;">' ||
                      '<tr style="background-color:#f2f2f2;"><th>Schema</th><th>Table</th><th>Change Classification</th><th>Impact Details</th></tr>';
                      
        -- Dynamically build html matrix lines from the drift summary
        SELECT email_body || LISTAGG('<tr><td>' || table_schema || '</td><td>' || table_name || '</td><td>' || change_category || '</td><td>' || details || '</td></tr>', '')
        INTO :email_body
        FROM schema_monitoring.detected_drift_summary;
        
        email_body := :email_body || '</table><p>Please check downstream pipelines or analytical tools relying on these structures.</p>';

        -- Call system stored procedure to fire the notification integration
        CALL SYSTEM$SEND_EMAIL(
            'schema_drift_email_int',
            'data_team_alerts@yourcompany.com', -- 👈 Must match the integration's allowed recipients
            :email_subject,
            :email_body,
            'text/html'
        );
    END IF;
END;
```

---

## 🚀 4. Activation & Operational Commands

Tasks are initialized in a `SUSPENDED` state by default. Run this final block to seed your baseline and activate the schedule.

```sql
-- Step A: Run a manual baseline snapshot before starting the engine 
-- This prevents false "COLUMN_ADDED" alerts on day one
INSERT INTO schema_monitoring.schema_snapshots (table_catalog, table_schema, table_name, column_name, data_type, ordinal_position, is_nullable)
SELECT table_catalog, table_schema, table_name, column_name, data_type, ordinal_position, is_nullable
FROM INFORMATION_SCHEMA.COLUMNS
WHERE table_schema NOT IN ('INFORMATION_SCHEMA', 'SCHEMA_MONITORING') 
  AND table_catalog = CURRENT_DATABASE();

-- Step B: Wake up the automated scheduler
ALTER TASK schema_monitoring.daily_schema_drift_check RESUME;

-- Operational Check: Manually trigger a run instantly to verify permissions
EXECUTE TASK schema_monitoring.daily_schema_drift_check;
```