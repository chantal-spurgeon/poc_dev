/* =============================================================================
   Snowflake Python Connector: version risk report
   -----------------------------------------------------------------------------
   Purpose : Find users whose sessions in the last 30 days used a Python
             Connector version that is
               (a) UNSUPPORTED,
               (b) NEARING END OF SUPPORT,
               (c) below the minimum version with no known CVEs, or
               (d) affected by any known CVE.
   Design  : Support thresholds are read LIVE from SYSTEM$CLIENT_VERSION_INFO(),
             so they update when Snowflake changes them each quarter.
             CVE data is not available in SQL, so it lives in one small table
             (CLIENT_CVE_RANGES). When a new CVE is published, add a row and
             everything else recalculates on its own, including the
             "minimum version with no CVEs".
   Requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (ACCOUNT_USAGE).
             ACCOUNT_USAGE.SESSIONS can lag by up to about 3 hours.
   Setup   : Replace ADMIN_DB.CLIENT_GOVERNANCE with your admin db.schema.
   CVE baseline current as of 2026-11-16.
   ============================================================================= */

CREATE SCHEMA IF NOT EXISTS ADMIN_DB.CLIENT_GOVERNANCE;

/* -----------------------------------------------------------------------------
   1. Helper: turns a version string into a number that sorts correctly
      ('4.10.0' > '4.9.1'). major*1e6 + minor*1e3 + patch. Pre-release
      suffixes (rc4, b1) are ignored, so 5.0.0rc4 is treated as 5.0.0.
   ----------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION ADMIN_DB.CLIENT_GOVERNANCE.SEMVER_KEY(V STRING)
RETURNS NUMBER(38,0)
COMMENT = 'Sortable numeric key for x.y.z version strings (major*1e6 + minor*1e3 + patch)'
AS
$$
    CASE WHEN REGEXP_SUBSTR(V, '^[0-9]+') IS NULL THEN NULL ELSE
          COALESCE(TRY_TO_NUMBER(REGEXP_SUBSTR(V, '^([0-9]+)',                1, 1, 'e', 1)), 0) * 1000000
        + COALESCE(TRY_TO_NUMBER(REGEXP_SUBSTR(V, '^[0-9]+[.]([0-9]+)',        1, 1, 'e', 1)), 0) * 1000
        + COALESCE(TRY_TO_NUMBER(REGEXP_SUBSTR(V, '^[0-9]+[.][0-9]+[.]([0-9]+)', 1, 1, 'e', 1)), 0)
    END
$$;

/* -----------------------------------------------------------------------------
   2. CVE baseline: one row per CVE per affected release line.
      AFFECTED_FROM is inclusive ('0' = every earlier version).
      FIXED_IN is exclusive (the first patched version on that line).
      CLIENT_ID matches the clientId from SYSTEM$CLIENT_VERSION_INFO, so the
      same table can later hold JDBC, ODBC, Go, and other drivers.
   ----------------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS ADMIN_DB.CLIENT_GOVERNANCE.CLIENT_CVE_RANGES (
    CLIENT_ID      STRING NOT NULL COMMENT 'clientId from SYSTEM$CLIENT_VERSION_INFO, e.g. PythonConnector',
    CVE_ID         STRING NOT NULL,
    AFFECTED_FROM  STRING NOT NULL COMMENT 'Inclusive lower bound; 0 = all earlier versions',
    FIXED_IN       STRING NOT NULL COMMENT 'Exclusive upper bound = first patched version on this line',
    SEVERITY       STRING,
    PUBLISHED_ON   DATE,
    SUMMARY        STRING,
    REFERENCE_URL  STRING,
    LOADED_AT      TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Re-runnable seed for the Python Connector
DELETE FROM ADMIN_DB.CLIENT_GOVERNANCE.CLIENT_CVE_RANGES WHERE CLIENT_ID = 'PythonConnector';

INSERT INTO ADMIN_DB.CLIENT_GOVERNANCE.CLIENT_CVE_RANGES
    (CLIENT_ID, CVE_ID, AFFECTED_FROM, FIXED_IN, SEVERITY, PUBLISHED_ON, SUMMARY, REFERENCE_URL)
VALUES
    ('PythonConnector','CVE-2026-123859','2.3.4' ,'4.8.1' ,'High'    ,'2026-11-06','write_pandas SQL injection via unescaped DataFrame column names (non-default identifier-escaping config)','https://nvd.nist.gov/vuln/detail/CVE-2026-123859'),
    ('PythonConnector','CVE-2026-123859','5.0.0' ,'5.2.0' ,'High'    ,'2026-11-06','write_pandas SQL injection, 5.x (Universal Core) line','https://nvd.nist.gov/vuln/detail/CVE-2026-123859'),
    ('PythonConnector','CVE-2026-114456','0'     ,'4.8.0' ,'Medium'  ,'2026-11-04','Missing Origin validation on the externalbrowser (SSO) local callback server','https://nvd.nist.gov/vuln/detail/CVE-2026-114456'),
    ('PythonConnector','CVE-2026-86597' ,'0'     ,'4.7.3' ,NULL      ,'2026-10-05','Tokens, encryption keys, presigned URLs, and SAML assertions written to diagnostic logs (no 3.x fix)','https://nvd.nist.gov/vuln/detail/CVE-2026-86597'),
    ('PythonConnector','CVE-2026-15925' ,'0'     ,'3.18.1','Critical','2026-07-16','Improper TLS hostname verification','https://nvd.nist.gov/vuln/detail/CVE-2026-15925'),
    ('PythonConnector','CVE-2026-15925' ,'4.0.0' ,'4.7.1' ,'Critical','2026-07-16','Improper TLS hostname verification, 4.x line','https://nvd.nist.gov/vuln/detail/CVE-2026-15925'),
    ('PythonConnector','CVE-2025-24795' ,'2.3.7' ,'3.13.1',NULL      ,'2025-01-29','Temporary credential cache created world-readable on Linux','https://nvd.nist.gov/vuln/detail/CVE-2025-24795'),
    ('PythonConnector','CVE-2025-24794' ,'2.7.12','3.13.1','Medium'  ,'2025-01-29','Insecure (pickle) deserialization of OCSP response cache','https://nvd.nist.gov/vuln/detail/CVE-2025-24794'),
    ('PythonConnector','CVE-2025-24793' ,'0'     ,'3.13.1','High'    ,'2025-01-29','SQL injection in write_pandas','https://nvd.nist.gov/vuln/detail/CVE-2025-24793'),
    ('PythonConnector','CVE-2024-49750' ,'0'     ,'3.12.3','Medium'  ,'2024-10-24','Sensitive data stored in logs','https://nvd.nist.gov/vuln/detail/CVE-2024-49750'),
    ('PythonConnector','CVE-2023-34233' ,'0'     ,'3.0.2' ,NULL      ,'2023-06-09','Command injection in browser-based SSO','https://nvd.nist.gov/vuln/detail/CVE-2023-34233');

/* -----------------------------------------------------------------------------
   3. Policy view: always returns one row with the current thresholds.
      MIN_NO_CVE_VERSION = the lowest patched version that no CVE range
      covers. It is derived from the table, so it moves when you add CVEs.
   ----------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW ADMIN_DB.CLIENT_GOVERNANCE.PYTHON_CONNECTOR_VERSION_POLICY
COMMENT = 'Live Python Connector thresholds: Snowflake support policy + derived minimum CVE-free version'
AS
WITH version_info AS (
    SELECT PARSE_JSON(SYSTEM$CLIENT_VERSION_INFO()) AS j
),
thresholds AS (
    SELECT
        f.value:minimumSupportedVersion::STRING           AS min_supported_version,
        f.value:minimumNearingEndOfSupportVersion::STRING AS nearing_eos_version,
        f.value:recommendedVersion::STRING                AS recommended_version
    FROM version_info v,
         LATERAL FLATTEN(INPUT => v.j) f
    WHERE f.value:clientId::STRING = 'PythonConnector'
),
cve AS (
    SELECT cve_id,
           ADMIN_DB.CLIENT_GOVERNANCE.SEMVER_KEY(affected_from) AS from_key,
           fixed_in,
           ADMIN_DB.CLIENT_GOVERNANCE.SEMVER_KEY(fixed_in)      AS fixed_key
    FROM ADMIN_DB.CLIENT_GOVERNANCE.CLIENT_CVE_RANGES
    WHERE client_id = 'PythonConnector'
),
clean_candidates AS (            -- patched versions that are not inside any other CVE range
    SELECT c.fixed_in AS version, c.fixed_key AS version_key
    FROM (SELECT DISTINCT fixed_in, fixed_key FROM cve) c
    LEFT JOIN cve r
           ON c.fixed_key >= r.from_key
          AND c.fixed_key <  r.fixed_key
    GROUP BY 1, 2
    HAVING COUNT(r.cve_id) = 0
)
SELECT
    t.min_supported_version,
    t.nearing_eos_version,
    t.recommended_version,
    (SELECT MIN_BY(version, version_key) FROM clean_candidates)                     AS min_no_cve_version,
    (SELECT ARRAY_AGG(version) WITHIN GROUP (ORDER BY version_key) FROM clean_candidates) AS cve_free_patch_floors,
    (SELECT MAX(loaded_at) FROM ADMIN_DB.CLIENT_GOVERNANCE.CLIENT_CVE_RANGES
      WHERE client_id = 'PythonConnector')                                          AS cve_baseline_loaded_at
FROM (SELECT 1 AS one) d
LEFT JOIN thresholds t ON 1 = 1;

/* -----------------------------------------------------------------------------
   4. Risk view: one row per user per connector version, last 30 days,
      limited to versions that need an upgrade.
   ----------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW ADMIN_DB.CLIENT_GOVERNANCE.PYTHON_CONNECTOR_UPGRADE_TARGETS
COMMENT = 'Users (last 30 days) on Python Connector versions that are unsupported, nearing EOS, below the CVE-free floor, or have known CVEs'
AS
WITH policy AS (
    SELECT p.*,
           ADMIN_DB.CLIENT_GOVERNANCE.SEMVER_KEY(min_supported_version) AS min_supported_key,
           ADMIN_DB.CLIENT_GOVERNANCE.SEMVER_KEY(nearing_eos_version)   AS nearing_eos_key,
           ADMIN_DB.CLIENT_GOVERNANCE.SEMVER_KEY(min_no_cve_version)    AS min_no_cve_key
    FROM ADMIN_DB.CLIENT_GOVERNANCE.PYTHON_CONNECTOR_VERSION_POLICY p
),
cve AS (
    SELECT cve_id,
           ADMIN_DB.CLIENT_GOVERNANCE.SEMVER_KEY(affected_from) AS from_key,
           ADMIN_DB.CLIENT_GOVERNANCE.SEMVER_KEY(fixed_in)      AS fixed_key
    FROM ADMIN_DB.CLIENT_GOVERNANCE.CLIENT_CVE_RANGES
    WHERE client_id = 'PythonConnector'
),
clean_floors AS (                -- same CVE-free patch floors as the policy view, one row each
    SELECT f.value::STRING AS version,
           ADMIN_DB.CLIENT_GOVERNANCE.SEMVER_KEY(f.value::STRING) AS version_key
    FROM policy p, LATERAL FLATTEN(INPUT => p.cve_free_patch_floors) f
),
py_sessions AS (
    SELECT
        s.session_id,
        s.user_name,
        s.created_on,
        s.authentication_method,
        COALESCE(REGEXP_SUBSTR(s.client_application_id, '[0-9]+[.][0-9]+[.][0-9]+[A-Za-z0-9]*'),
                 'UNKNOWN')                               AS connector_version,
        TRY_PARSE_JSON(TO_VARCHAR(s.client_environment))  AS env
    FROM SNOWFLAKE.ACCOUNT_USAGE.SESSIONS s
    WHERE s.created_on >= DATEADD(DAY, -30, CURRENT_TIMESTAMP())      -- reporting window
      AND s.client_application_id ILIKE 'PythonConnector%'
),
versions AS (
    SELECT DISTINCT connector_version,
           ADMIN_DB.CLIENT_GOVERNANCE.SEMVER_KEY(connector_version) AS version_key
    FROM py_sessions
),
version_cves AS (
    SELECT v.connector_version,
           COUNT(DISTINCT c.cve_id)                                               AS known_cve_count,
           LISTAGG(DISTINCT c.cve_id, ', ') WITHIN GROUP (ORDER BY c.cve_id DESC) AS known_cve_ids
    FROM versions v
    JOIN cve c
      ON v.version_key >= c.from_key
     AND v.version_key <  c.fixed_key
    GROUP BY 1
),
next_clean AS (                  -- nearest CVE-free version at or above the one in use
    SELECT v.connector_version, MIN_BY(cf.version, cf.version_key) AS next_clean_version
    FROM versions v
    JOIN clean_floors cf ON cf.version_key >= v.version_key
    GROUP BY 1
),
classified AS (
    SELECT
        v.connector_version,
        CASE
            WHEN v.version_key IS NULL                 THEN 'UNKNOWN_VERSION'
            WHEN v.version_key <  p.min_supported_key  THEN 'UNSUPPORTED'
            -- Inclusive on purpose: flags the version Snowflake names as reaching EOS next quarter
            WHEN v.version_key <= p.nearing_eos_key    THEN 'NEARING_END_OF_SUPPORT'
            ELSE 'SUPPORTED'
        END                                            AS support_status,
        COALESCE(v.version_key < p.min_no_cve_key, FALSE) AS below_min_no_cve_version,
        COALESCE(vc.known_cve_count, 0)                AS known_cve_count,
        vc.known_cve_ids,
        p.min_supported_version,
        p.nearing_eos_version,
        p.recommended_version,
        p.min_no_cve_version,
        nc.next_clean_version
    FROM versions v
    LEFT JOIN policy       p  ON 1 = 1
    LEFT JOIN version_cves vc ON vc.connector_version = v.connector_version
    LEFT JOIN next_clean   nc ON nc.connector_version = v.connector_version
)
SELECT
    ps.user_name,
    u.type                                         AS user_type,     -- PERSON / SERVICE / LEGACY_SERVICE
    u.email,
    u.owner                                        AS user_owner_role,
    c.connector_version,
    c.support_status,
    c.below_min_no_cve_version,
    c.known_cve_count,
    c.known_cve_ids,
    CASE
        WHEN c.known_cve_count > 0 OR c.below_min_no_cve_version
             THEN '>= ' || COALESCE(c.next_clean_version, c.min_no_cve_version)
        WHEN c.support_status <> 'SUPPORTED'
             THEN '>= ' || c.recommended_version
    END                                            AS suggested_upgrade_to,
    COUNT(*)                                       AS session_count,
    MIN(ps.created_on)                             AS first_seen,
    MAX(ps.created_on)                             AS last_seen,
    ARRAY_AGG(DISTINCT ps.env:APPLICATION::STRING)    AS client_applications,  -- e.g. Snowpark, dbt, Airflow
    ARRAY_AGG(DISTINCT ps.env:PYTHON_VERSION::STRING) AS python_versions,
    ARRAY_AGG(DISTINCT ps.env:OS::STRING)             AS operating_systems,
    ARRAY_AGG(DISTINCT ps.authentication_method)      AS auth_methods,
    c.min_supported_version,
    c.nearing_eos_version,
    c.recommended_version,
    c.min_no_cve_version
FROM py_sessions ps
JOIN classified c
  ON c.connector_version = ps.connector_version
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u
  ON u.name = ps.user_name
 AND u.deleted_on IS NULL
WHERE c.support_status <> 'SUPPORTED'
   OR c.below_min_no_cve_version
   OR c.known_cve_count > 0
GROUP BY ALL;

/* =============================================================================
   5. Day-to-day usage
   ============================================================================= */

-- Current thresholds (check this first)
SELECT * FROM ADMIN_DB.CLIENT_GOVERNANCE.PYTHON_CONNECTOR_VERSION_POLICY;

-- Full upgrade list, worst first
SELECT *
FROM ADMIN_DB.CLIENT_GOVERNANCE.PYTHON_CONNECTOR_UPGRADE_TARGETS
ORDER BY
    CASE support_status WHEN 'UNSUPPORTED' THEN 1 WHEN 'UNKNOWN_VERSION' THEN 2
                        WHEN 'NEARING_END_OF_SUPPORT' THEN 3 ELSE 4 END,
    known_cve_count DESC,
    session_count DESC;

-- One row per user (for outreach)
SELECT user_name, user_type, email,
       ARRAY_AGG(DISTINCT connector_version)  AS versions_in_use,
       MAX(known_cve_count)                   AS worst_cve_count,
       ARRAY_AGG(DISTINCT support_status)     AS statuses,
       SUM(session_count)                     AS sessions_30d,
       MAX(last_seen)                         AS last_seen
FROM ADMIN_DB.CLIENT_GOVERNANCE.PYTHON_CONNECTOR_UPGRADE_TARGETS
GROUP BY ALL
ORDER BY worst_cve_count DESC, sessions_30d DESC;

/* =============================================================================
   6. Maintenance: when a new Python Connector CVE is published
   -----------------------------------------------------------------------------
   Add one row per affected release line. Nothing else changes:
   MIN_NO_CVE_VERSION, KNOWN_CVE_IDS, and SUGGESTED_UPGRADE_TO recalculate.

   INSERT INTO ADMIN_DB.CLIENT_GOVERNANCE.CLIENT_CVE_RANGES
       (CLIENT_ID, CVE_ID, AFFECTED_FROM, FIXED_IN, SEVERITY, PUBLISHED_ON, SUMMARY, REFERENCE_URL)
   VALUES ('PythonConnector', 'CVE-YYYY-NNNNN', '0', 'x.y.z', 'High', 'YYYY-MM-DD',
           'short description', 'https://nvd.nist.gov/vuln/detail/CVE-YYYY-NNNNN');

   Where to check: snowflake.com Security Hub bulletins, GitHub advisories for
   snowflakedb/snowflake-connector-python, or OSV (osv.dev, package
   snowflake-connector-python).
   ============================================================================= */
