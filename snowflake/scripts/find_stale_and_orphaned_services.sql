/*
  find_stale_and_orphaned_services.sql

  Purpose : Flag Snowpark Container Services services that are candidates for
            cleanup:
              1. STALE      - not running, and not resumed (or created, if never
                              resumed) in the last N days (default 90)
              2. ORPHANED   - managed by a Streamlit/Notebook that no longer exists
              3. SUPERSEDED - an older service managed by the same Streamlit/Notebook
                              as a newer one (typical left-over after a redeploy)
              4. FINISHED JOB - job services in DONE/FAILED state older than N days

  Run as  : A role with visibility to all services, Streamlits and notebooks
            (e.g. ACCOUNTADMIN). Run the whole script top to bottom in one
            session ("Run All") - each step reads the previous SHOW result.

  Notes   : Nothing is dropped. Review the generated DROP statements first.
            managing_object_domain / managing_object_name are documented as NULL
            when a service isn't managed by a Snowflake entity; the matching
            below normalises quotes and case and accepts either a fully
            qualified or a bare name, but check a few rows against
            DESC SERVICE before trusting the ORPHANED flag.
*/

SET stale_days = 90;

------------------------------------------------------------------
-- 1. Snapshot of all services (including job services)
------------------------------------------------------------------
SHOW SERVICES IN ACCOUNT;

CREATE OR REPLACE TEMPORARY TABLE svc_snapshot AS
SELECT "name"                    AS service_name,
       "database_name"           AS database_name,
       "schema_name"             AS schema_name,
       "status"                  AS status,
       "is_job"                  AS is_job,
       "owner"                   AS owner,
       "compute_pool"            AS compute_pool,
       "current_instances"       AS current_instances,
       "auto_resume"             AS auto_resume,
       "created_on"              AS created_on,
       "updated_on"              AS updated_on,
       "resumed_on"              AS resumed_on,
       "suspended_on"            AS suspended_on,
       "managing_object_domain"  AS managing_object_domain,
       "managing_object_name"    AS managing_object_name,
       "comment"                 AS comment
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

------------------------------------------------------------------
-- 2. Objects that can manage a service
------------------------------------------------------------------
SHOW STREAMLITS IN ACCOUNT;

CREATE OR REPLACE TEMPORARY TABLE mgr_streamlits AS
SELECT UPPER("database_name" || '.' || "schema_name" || '.' || "name") AS fq_name,
       UPPER("name")                                                  AS bare_name
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW NOTEBOOKS IN ACCOUNT;

CREATE OR REPLACE TEMPORARY TABLE mgr_notebooks AS
SELECT UPPER("database_name" || '.' || "schema_name" || '.' || "name") AS fq_name,
       UPPER("name")                                                  AS bare_name
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

------------------------------------------------------------------
-- 3. Classify
------------------------------------------------------------------
WITH svc AS (
    SELECT s.*,
           UPPER(s.managing_object_domain)                          AS mgr_domain,
           REPLACE(UPPER(s.managing_object_name), '"', '')          AS mgr_name,
           COALESCE(s.resumed_on, s.created_on)                     AS last_started,
           DATEDIFF('day', COALESCE(s.resumed_on, s.created_on),
                    CURRENT_TIMESTAMP())                            AS days_since_started
      FROM svc_snapshot s
),
mgr AS (
    SELECT 'STREAMLIT' AS domain, fq_name, bare_name FROM mgr_streamlits
    UNION ALL
    SELECT 'NOTEBOOK',            fq_name, bare_name FROM mgr_notebooks
),
flagged AS (
    SELECT svc.*,
           -- Managing object still exists?
           CASE
             WHEN svc.mgr_domain IS NULL                     THEN NULL
             WHEN svc.mgr_domain NOT IN ('STREAMLIT','NOTEBOOK') THEN NULL   -- domain not checked
             ELSE NOT EXISTS (
                    SELECT 1 FROM mgr m
                     WHERE m.domain = svc.mgr_domain
                       AND (m.fq_name = svc.mgr_name
                            OR (CONTAINS(svc.mgr_name, '.') = FALSE
                                AND m.bare_name = svc.mgr_name)))
           END                                                     AS is_orphaned,
           -- Newer service exists for the same managing object?
           IFF(svc.mgr_name IS NOT NULL,
               ROW_NUMBER() OVER (PARTITION BY svc.mgr_domain, svc.mgr_name
                                  ORDER BY svc.created_on DESC) > 1,
               FALSE)                                              AS is_superseded,
           -- Not running and not started in N days
           (svc.status NOT IN ('RUNNING','PENDING')
             AND svc.days_since_started >= $stale_days
             AND COALESCE(svc.is_job, FALSE) = FALSE)              AS is_stale,
           -- Finished job services
           (COALESCE(svc.is_job, FALSE)
             AND svc.status IN ('DONE','FAILED')
             AND DATEDIFF('day', COALESCE(svc.updated_on, svc.created_on),
                          CURRENT_TIMESTAMP()) >= $stale_days)     AS is_finished_job
      FROM svc
)
SELECT database_name || '.' || schema_name || '.' || service_name     AS service_fqn,
       status,
       is_job,
       compute_pool,
       owner,
       managing_object_domain,
       managing_object_name,
       created_on,
       resumed_on,
       suspended_on,
       days_since_started,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
           IFF(is_orphaned,     'ORPHANED (managing object not found)', NULL),
           IFF(is_superseded,   'SUPERSEDED (newer service for same object)', NULL),
           IFF(is_stale,        'STALE (not started in ' || $stale_days || '+ days)', NULL),
           IFF(is_finished_job, 'FINISHED JOB', NULL)), '; ')         AS cleanup_reasons,
       'DROP SERVICE "' || REPLACE(database_name, '"', '""') || '"."'
                        || REPLACE(schema_name,   '"', '""') || '"."'
                        || REPLACE(service_name,  '"', '""') || '";' AS drop_statement
  FROM flagged
 WHERE COALESCE(is_orphaned, FALSE)
    OR is_superseded
    OR is_stale
    OR is_finished_job
 ORDER BY is_orphaned DESC NULLS LAST, is_superseded DESC, days_since_started DESC;

------------------------------------------------------------------
-- Optional: services managed by a domain this script doesn't check
------------------------------------------------------------------
-- SELECT * FROM svc_snapshot
--  WHERE managing_object_domain IS NOT NULL
--    AND UPPER(managing_object_domain) NOT IN ('STREAMLIT','NOTEBOOK');
