-- ============================================================================
-- SNOWFLAKE END-TO-END PIPELINE: HIGH-VOLUME DATA INGESTION & PII GOVERNANCE
-- Purpose: Test pipeline demonstration for prospective employers
-- Architecture: GCP GCS -> Snowpipe -> Raw Layer (Variant) -> Streams/Tasks -> Secure Analytics Layer
-- Security: Dynamic Data Masking & Row-Level Access Policies
-- ============================================================================

-- ============================================================================
-- 1. INFRASTRUCTURE & ROLE MANAGEMENT
-- ============================================================================
USE ROLE ACCOUNTADMIN;

-- Create dedicated roles to demonstrate RBAC (Role-Based Access Control)
CREATE ROLE IF NOT EXISTS data_engineer_role;
CREATE ROLE IF NOT EXISTS security_admin_role;
CREATE ROLE IF NOT EXISTS general_analyst_role;

-- Grant required operational privileges
GRANT CREATE DATABASE ON ACCOUNT TO ROLE data_engineer_role;
GRANT CREATE INTEGRATION ON ACCOUNT TO ROLE data_engineer_role;
GRANT APPLY MASKING POLICY ON ACCOUNT TO ROLE security_admin_role;
GRANT APPLY ROW ACCESS POLICY ON ACCOUNT TO ROLE security_admin_role;

-- Create Warehouse optimized for high-volume transformations
CREATE WAREHOUSE IF NOT EXISTS census_ingest_wh
    WITH WAREHOUSE_SIZE = 'MEDIUM'
    AUTO_SUSPEND = 60 -- Minimizes idle compute cost
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Warehouse for processing large-scale census datasets';

GRANT USAGE ON WAREHOUSE census_ingest_wh TO ROLE data_engineer_role;
GRANT USAGE ON WAREHOUSE census_ingest_wh TO ROLE general_analyst_role;

-- ============================================================================
-- 2. DATABASE, SCHEMAS, AND MULTI-LAYER STORAGE
-- ============================================================================
USE ROLE data_engineer_role;

CREATE DATABASE IF NOT EXISTS census_db;
USE DATABASE census_db;

-- Establish a multi-layer schema architecture
CREATE SCHEMA IF NOT EXISTS raw_ingest;      -- Landing area for source records
CREATE SCHEMA IF NOT EXISTS secure_analytics; -- Cleaned, governed, production layer

-- ============================================================================
-- 3. GCP INTEGRATION & STAGE DEFINITIONS
-- ============================================================================
USE SCHEMA raw_ingest;

-- Create Cloud Storage Integration (Requires GCP IAM configuration on bucket)
CREATE OR REPLACE STORAGE INTEGRATION gcs_census_integration
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'GCS'
    ENABLED = TRUE
    STORAGE_ALLOWED_LOCATIONS = ('gcs://your-census-data-bucket-name/incoming/');

-- Retrieve integration service account to show interviewer you understand GCP IAM syncing
DESCRIBE STORAGE INTEGRATION gcs_census_integration;
-- * Note for interview: Copy the STORAGE_GCP_SERVICE_ACCOUNT parameter and grant it 
--   Storage Object Viewer permissions inside your GCP Cloud Storage bucket console.

-- Create reusable file format for massive JSON/Newline-JSON dumps
CREATE OR REPLACE FILE FORMAT json_file_format
    TYPE = 'JSON'
    STRIP_OUTER_ARRAY = TRUE
    COMPRESSION = 'AUTO';

-- Create external stage pointing directly to the GCS bucket path
CREATE OR REPLACE STAGE gcs_census_stage
    URL = 'gcs://your-census-data-bucket-name/incoming/'
    STORAGE_INTEGRATION = gcs_census_integration
    FILE_FORMAT = json_file_format;

-- ============================================================================
-- 4. RAW INGESTION LAYER (Variant Landing Plan)
-- ============================================================================

-- Optimal practice: Store raw payload unmodified to adapt dynamically to census schema drifts
CREATE OR REPLACE TABLE census_raw_landing (
    raw_payload VARIANT,
    ingested_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    source_file_name STRING METADATA$FILENAME,
    source_file_row_number INT METADATA$FILE_ROW_NUMBER
);

-- ============================================================================
-- 5. AUTOMATED ASYNCHRONOUS INGESTION (Snowpipe via GCP Pub/Sub)
-- ============================================================================

CREATE OR REPLACE PIPE census_db.raw_ingest.snowpipe_census_ingest
    AUTO_INGEST = TRUE
    INTEGRATION = 'YOUR_GCP_PUBSUB_NOTIFICATION_INTEGRATION_NAME' -- Connects to GCS bucket notification
    AS
    COPY INTO census_db.raw_ingest.census_raw_landing (raw_payload)
    FROM @census_db.raw_ingest.gcs_census_stage;

-- * Note for interview: Execute 'DESCRIBE PIPE snowpipe_census_ingest;' to copy the 
--   notification channel ID and paste it into your GCP Pub/Sub subscription topic.

-- ============================================================================
-- 6. CHANGE DATA CAPTURE (CDC) USING STREAMS
-- ============================================================================

-- A stream tracks append-only data hitting raw landing, avoiding resource-heavy full table scans
CREATE OR REPLACE STREAM census_raw_stream 
    ON TABLE census_raw_landing
    APPEND_ONLY = TRUE;

-- ============================================================================
-- 7. SECURE PRODUCTION ANALYTICS LAYER (Target Physical Schema)
-- ============================================================================
USE SCHEMA secure_analytics;

CREATE OR REPLACE TABLE census_demographics_final (
    citizen_id INT,
    first_name STRING,
    last_name STRING,
    ssn STRING,
    birth_date DATE,
    gender STRING,
    state_code STRING,
    annual_income NUMBER(12,2),
    household_size INT,
    education_level STRING,
    employment_status STRING,
    processed_at TIMESTAMP_LTZ
);

-- ============================================================================
-- 8. ENTERPRISE DATA GOVERNANCE & SECURITY POLICIES (PII Protections)
-- ============================================================================
USE ROLE security_admin_role;
USE DATABASE census_db;
USE SCHEMA secure_analytics;

-- 8a. Dynamic Data Masking: Complete redaction for unauthorized users
CREATE OR REPLACE MASKING POLICY ssn_mask AS (val STRING) RETURNS STRING ->
    CASE 
        WHEN CURRENT_ROLE() IN ('ACCOUNTADMIN', 'SECURITY_ADMIN_ROLE') THEN val
        ELSE 'XXX-XX-' || RIGHT(val, 4) -- Partially masks SSN for general analytics
    END;

CREATE OR REPLACE MASKING POLICY name_mask AS (val STRING) RETURNS STRING ->
    CASE 
        WHEN CURRENT_ROLE() IN ('ACCOUNTADMIN', 'SECURITY_ADMIN_ROLE') THEN val
        ELSE 'CONFIDENTIAL' -- Fully obfuscates names for compliance
    END;

-- Apply Data Masking Policies to production columns
ALTER TABLE census_demographics_final ALTER COLUMN ssn SET MASKING POLICY ssn_mask;
ALTER TABLE census_demographics_final ALTER COLUMN first_name SET MASKING POLICY name_mask;
ALTER TABLE census_demographics_final ALTER COLUMN last_name SET MASKING POLICY name_mask;

-- 8b. Row-Level Access Control (RLAC): Geographically isolating rows based on user session context
CREATE OR REPLACE ROW ACCESS POLICY state_isolation_policy 
    AS (state_code STRING) RETURNS BOOLEAN ->
        CURRENT_ROLE() IN ('ACCOUNTADMIN', 'SECURITY_ADMIN_ROLE', 'DATA_ENGINEER_ROLE')
        OR 
        -- Simulates matching an analyst's role structure to specific US state boundaries
        CURRENT_ROLE() = 'ANALYST_' || UPPER(state_code);

-- Apply Row Access Policy to physical table
ALTER TABLE census_demographics_final ADD ROW ACCESS POLICY state_isolation_policy ON (state_code);

-- ============================================================================
-- 9. SERVERLESS AUTOMATION ENGINE (Transforms & Flattens JSON Streams)
-- ============================================================================
USE ROLE data_engineer_role;
USE SCHEMA secure_analytics;

-- The serverless task triggers automatically only if the stream contains unparsed changes
CREATE OR REPLACE TASK process_census_stream_task
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'SMALL'
    SCHEDULE = 'USING CRON */5 * * * * UTC' -- Evaluates stream updates every 5 minutes
    WHEN SYSTEM$STREAM_HAS_DATA('census_db.raw_ingest.census_raw_stream')
    AS
    INSERT INTO census_db.secure_analytics.census_demographics_final
    SELECT
        (raw_payload:citizen_id)::INT,
        (raw_payload:first_name)::STRING,
        (raw_payload:last_name)::STRING,
        (raw_payload:ssn)::STRING,
        (raw_payload:birth_date)::DATE,
        (raw_payload:gender)::STRING,
        (raw_payload:state_code)::STRING,
        (raw_payload:annual_income)::NUMBER(12,2),
        (raw_payload:household_size)::INT,
        (raw_payload:education_level)::STRING,
        (raw_payload:employment_status)::STRING,
        CURRENT_TIMESTAMP()
    FROM census_db.raw_ingest.census_raw_stream
    WHERE METADATA$ACTION = 'INSERT'; -- Ingests fresh logs exclusively

-- Resume the task engine to enable continuous scheduled checks
ALTER TASK process_census_stream_task RESUME;

-- ============================================================================
-- 10. VERIFICATION & MANIFEST DEMO SCRIPTS (For Interview Visuals)
-- ============================================================================

-- Simulating raw data injection manually for test evaluation
/*
INSERT INTO census_db.raw_ingest.census_raw_landing (raw_payload)
SELECT PARSE_JSON('{
    "citizen_id": 99482,
    "first_name": "Jane",
    "last_name": "Doe",
    "ssn": "123-456-7890",
    "birth_date": "1988-11-23",
    "gender": "Female",
    "state_code": "CA",
    "annual_income": 94500.00,
    "household_size": 3,
    "education_level": "Bachelors",
    "employment_status": "Employed"
}');

-- Force execute the task instead of waiting 5 minutes for automated cron
EXECUTE TASK process_census_stream_task;
*/

-- Observe how the policies dynamically affect visibility across different role definitions:
/*
-- 1. View as Data Admin (Full Clarity)
USE ROLE data_engineer_role;
SELECT citizen_id, first_name, last_name, ssn, state_code, annual_income FROM census_db.secure_analytics.census_demographics_final;

-- 2. View as Restricted General Analyst (Demonstrates PII compliance block)
USE ROLE general_analyst_role;
SELECT citizen_id, first_name, last_name, ssn, state_code, annual_income FROM census_db.secure_analytics.census_demographics_final;
-- Note: Names will change to 'CONFIDENTIAL', SSN will only render last 4 digits, and rows are filtered based on session access role permissions.
*/
