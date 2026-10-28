/* =====================================================================
   Egress charges per role per month — refreshed daily
   ---------------------------------------------------------------------
   Source : SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY (outbound_data_transfer_*)
   Scope  : Snowflake-billed egress from unloads (COPY INTO @stage, etc.).
            GCS -> Snowflake loads are billed by Google and are NOT here.
   Rates  : Your original rates. Confirm against your Snowflake rate card.

   Replace before running:
     <admin_role>     role that will own the table, procedure, and task
     ADMIN_DB.FINOPS  database.schema for the objects
     ADMIN_WH         warehouse for the task (or use the serverless option)
   ===================================================================== */

USE ROLE <admin_role>;
USE SCHEMA ADMIN_DB.FINOPS;

/* ---------------------------------------------------------------------
   0. One-time grants (run as ACCOUNTADMIN)
   --------------------------------------------------------------------- */
-- GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE <admin_role>;
-- GRANT EXECUTE TASK ON ACCOUNT TO ROLE <admin_role>;
-- GRANT EXECUTE MANAGED TASK ON ACCOUNT TO ROLE <admin_role>;  -- only if serverless

/* ---------------------------------------------------------------------
   1. Target table (one row per month / role / destination)
   --------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS EGRESS_BY_ROLE_MONTHLY (
    month             DATE,
    role_name         VARCHAR,
    target_cloud      VARCHAR,        -- destination cloud of the unload
    target_region     VARCHAR,        -- destination region, e.g. us-central1
    target_region_id  VARCHAR,        -- e.g. GCP_US_CENTRAL1, comparable to CURRENT_REGION()
    unload_queries    NUMBER,
    gb_out            NUMBER(18,2),
    rate_per_gb       NUMBER(10,4),
    est_cost_usd      NUMBER(18,2),
    refreshed_at      TIMESTAMP_LTZ
);

/* ---------------------------------------------------------------------
   2. Refresh procedure
      Recomputes the current AND prior month in full each run, so it is
      idempotent and catches late rows across the month boundary
      (ACCOUNT_USAGE latency is up to ~45 min for QUERY_HISTORY).
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE REFRESH_EGRESS_BY_ROLE_MONTHLY()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    MERGE INTO EGRESS_BY_ROLE_MONTHLY t
    USING (
        WITH q AS (
            SELECT DATE_TRUNC('month', start_time)::DATE                  AS month,
                   COALESCE(role_name, '<none>')                          AS role_name,
                   UPPER(outbound_data_transfer_cloud)                    AS target_cloud,
                   LOWER(COALESCE(outbound_data_transfer_region, ''))     AS target_region,
                   UPPER(outbound_data_transfer_cloud) || '_' ||
                     REPLACE(UPPER(COALESCE(outbound_data_transfer_region, '')), '-', '_')
                                                                          AS target_region_id,
                   outbound_data_transfer_bytes                           AS bytes_out
            FROM snowflake.account_usage.query_history
            WHERE start_time >= DATEADD('month', -1, DATE_TRUNC('month', CURRENT_DATE()))
              AND outbound_data_transfer_bytes > 0
              AND outbound_data_transfer_cloud IS NOT NULL
        ),
        agg AS (
            SELECT month, role_name, target_cloud, target_region, target_region_id,
                   COUNT(*)                       AS unload_queries,
                   SUM(bytes_out) / POWER(1024, 3) AS gb_raw
            FROM q
            GROUP BY 1, 2, 3, 4, 5
        ),
        rated AS (
            SELECT agg.*,
                   CASE
                       -- same region as this account: no charge
                       -- (SPLIT_PART strips an org region-group prefix, e.g. PUBLIC.)
                       WHEN target_region_id = SPLIT_PART(CURRENT_REGION(), '.', -1) THEN 0
                       WHEN target_cloud = 'AWS' AND target_region = 'us-east-1'     THEN 0.02
                       ELSE 0.09
                   END AS rate_per_gb
            FROM agg
        )
        SELECT month, role_name, target_cloud, target_region, target_region_id,
               unload_queries,
               ROUND(gb_raw, 2)               AS gb_out,
               rate_per_gb,
               ROUND(gb_raw * rate_per_gb, 2) AS est_cost_usd
        FROM rated
    ) s
    ON  t.month         = s.month
    AND t.role_name     = s.role_name
    AND t.target_cloud  = s.target_cloud
    AND t.target_region = s.target_region
    WHEN MATCHED THEN UPDATE SET
        t.target_region_id = s.target_region_id,
        t.unload_queries   = s.unload_queries,
        t.gb_out           = s.gb_out,
        t.rate_per_gb      = s.rate_per_gb,
        t.est_cost_usd     = s.est_cost_usd,
        t.refreshed_at     = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
        (month, role_name, target_cloud, target_region, target_region_id,
         unload_queries, gb_out, rate_per_gb, est_cost_usd, refreshed_at)
    VALUES
        (s.month, s.role_name, s.target_cloud, s.target_region, s.target_region_id,
         s.unload_queries, s.gb_out, s.rate_per_gb, s.est_cost_usd, CURRENT_TIMESTAMP());

    RETURN 'EGRESS_BY_ROLE_MONTHLY refreshed: ' || SQLROWCOUNT || ' rows merged';
END;
$$;

/* ---------------------------------------------------------------------
   3. Daily task — 6:00 AM Central
      Option A (shown): runs on an existing warehouse.
      Option B: serverless — remove the WAREHOUSE line and add
                USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
   --------------------------------------------------------------------- */
CREATE OR REPLACE TASK REFRESH_EGRESS_BY_ROLE_MONTHLY_TASK
    WAREHOUSE = ADMIN_WH
    SCHEDULE  = 'USING CRON 0 6 * * * America/Chicago'
    COMMENT   = 'Daily refresh of estimated egress cost per role per month'
AS
    CALL REFRESH_EGRESS_BY_ROLE_MONTHLY();

-- Tasks are created suspended; resume to start the schedule.
ALTER TASK REFRESH_EGRESS_BY_ROLE_MONTHLY_TASK RESUME;

-- Optional: run once now to backfill current and prior month.
EXECUTE TASK REFRESH_EGRESS_BY_ROLE_MONTHLY_TASK;

/* ---------------------------------------------------------------------
   4. Check runs and read results
   --------------------------------------------------------------------- */
SELECT name, state, scheduled_time, completed_time, return_value, error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
       TASK_NAME => 'REFRESH_EGRESS_BY_ROLE_MONTHLY_TASK',
       RESULT_LIMIT => 10))
ORDER BY scheduled_time DESC;

-- Report view with currency formatting (keep the table numeric)
SELECT month,
       role_name,
       target_cloud,
       target_region,
       unload_queries,
       gb_out,
       TO_VARCHAR(est_cost_usd, '$999,999,990.00') AS est_cost,
       refreshed_at
FROM EGRESS_BY_ROLE_MONTHLY
WHERE gb_out > 0
ORDER BY month DESC, est_cost_usd DESC;
