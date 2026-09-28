# Snowflake Openflow: Draft Role Model and Runbook

**Status:** Draft for review. Names, domains, and sizes are placeholders (example domain: `SALES`, example source: PostgreSQL). Items marked **VERIFY** were not confirmed against current Snowflake documentation and should be tested in a sandbox first.

---

## 1. Role model

### Design principles
- Separate **platform administration** (deployments, compute pools, integrations) from **pipeline work** (runtimes, flows, landing data).
- One **runtime role per domain and environment**, so a runtime can only write where it should.
- Engineers never hold production runtime roles directly. Prod is changed by the admin role (or an automation user).
- Network access is granted per source through external access integrations, not one shared "allow everything" integration.

### Roles

| Role | Type | Purpose | Granted to |
|---|---|---|---|
| `OPENFLOW_ADMIN` | Functional | Creates and manages deployments, compute pools, network rules, and external access integrations | Platform admins / DBAs; rolled up to `SYSADMIN` |
| `OF_RT_<DOMAIN>_<ENV>` | Runtime | Identity the runtime uses: writes to the landing database, uses the warehouse and integrations | `OPENFLOW_ADMIN`; the engineer role (DEV only) |
| `OF_ENGINEER_<DOMAIN>` | Functional | What data engineers hold day to day; inherits DEV runtime roles | Data engineers |
| `RAW_<DOMAIN>_<ENV>_RO` | Access | Read-only access to landed data | Downstream roles / analysts |

### Object naming

| Object | Pattern | Example |
|---|---|---|
| Admin database (network rules) | `OPENFLOW_ADMIN_DB` | `OPENFLOW_ADMIN_DB.NETWORKS` |
| Landing database | `RAW_<DOMAIN>_<ENV>` | `RAW_SALES_DEV` |
| Warehouse | `OF_WH_<DOMAIN>_<ENV>` | `OF_WH_SALES_DEV` |
| Resource monitor | `OF_RM_<DOMAIN>_<ENV>` | `OF_RM_SALES_DEV` |
| Network rule | `NR_<SOURCE>_<ENV>` | `NR_PG_SALES_DEV` |
| External access integration | `EAI_<SOURCE>_<ENV>` | `EAI_PG_SALES_DEV` |

### Environment matrix

| | DEV | PROD |
|---|---|---|
| Engineer can create/edit flows | Yes | No (admin or automation only) |
| Engineer holds runtime role | Yes | No |
| Warehouse size | Small, tight credit quota | Sized to load, monitored |
| Source credentials | Non-production sources | Production sources, rotated per policy |

---

## 2. Grant script (template)

Replace the placeholders. Run each block under the role shown. Repeat the domain blocks for each domain and environment.

```sql
-------------------------------------------------------------------
-- 0. Roles (USERADMIN)
-------------------------------------------------------------------
USE ROLE USERADMIN;
CREATE ROLE IF NOT EXISTS OPENFLOW_ADMIN;
CREATE ROLE IF NOT EXISTS OF_RT_SALES_DEV;
CREATE ROLE IF NOT EXISTS OF_ENGINEER_SALES;
CREATE ROLE IF NOT EXISTS RAW_SALES_DEV_RO;

-- Role hierarchy
GRANT ROLE OF_RT_SALES_DEV    TO ROLE OPENFLOW_ADMIN;
GRANT ROLE OF_RT_SALES_DEV    TO ROLE OF_ENGINEER_SALES;   -- DEV only
GRANT ROLE OPENFLOW_ADMIN     TO ROLE SYSADMIN;

-------------------------------------------------------------------
-- 1. Account-level privileges for the admin role (ACCOUNTADMIN)
-------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;
GRANT CREATE DATABASE, CREATE COMPUTE POOL, CREATE INTEGRATION,
      BIND SERVICE ENDPOINT
  ON ACCOUNT TO ROLE OPENFLOW_ADMIN;

-------------------------------------------------------------------
-- 2. Warehouse and cost guardrail (ACCOUNTADMIN, one-time per domain/env)
-------------------------------------------------------------------
CREATE RESOURCE MONITOR IF NOT EXISTS OF_RM_SALES_DEV
  WITH CREDIT_QUOTA = 50
  TRIGGERS ON 80 PERCENT DO NOTIFY
           ON 100 PERCENT DO SUSPEND;

CREATE WAREHOUSE IF NOT EXISTS OF_WH_SALES_DEV
  WAREHOUSE_SIZE = SMALL
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  RESOURCE_MONITOR = OF_RM_SALES_DEV;

GRANT USAGE ON WAREHOUSE OF_WH_SALES_DEV TO ROLE OF_RT_SALES_DEV;

-------------------------------------------------------------------
-- 3. Databases and network rules (OPENFLOW_ADMIN)
-------------------------------------------------------------------
USE ROLE OPENFLOW_ADMIN;

CREATE DATABASE IF NOT EXISTS OPENFLOW_ADMIN_DB;
CREATE SCHEMA   IF NOT EXISTS OPENFLOW_ADMIN_DB.NETWORKS;

CREATE DATABASE IF NOT EXISTS RAW_SALES_DEV;

-- Runtime role writes here. CREATE SCHEMA is included because connectors
-- typically create destination objects. VERIFY exact needs per connector.
GRANT USAGE, CREATE SCHEMA ON DATABASE RAW_SALES_DEV TO ROLE OF_RT_SALES_DEV;

-- Read-only access for consumers, including objects created later
GRANT USAGE ON DATABASE RAW_SALES_DEV TO ROLE RAW_SALES_DEV_RO;
GRANT USAGE  ON FUTURE SCHEMAS IN DATABASE RAW_SALES_DEV TO ROLE RAW_SALES_DEV_RO;
GRANT SELECT ON FUTURE TABLES  IN DATABASE RAW_SALES_DEV TO ROLE RAW_SALES_DEV_RO;

-------------------------------------------------------------------
-- 4. Network access per source (OPENFLOW_ADMIN)
-------------------------------------------------------------------
CREATE OR REPLACE NETWORK RULE OPENFLOW_ADMIN_DB.NETWORKS.NR_PG_SALES_DEV
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('your-postgres-host.example.com:5432');

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION EAI_PG_SALES_DEV
  ALLOWED_NETWORK_RULES = (OPENFLOW_ADMIN_DB.NETWORKS.NR_PG_SALES_DEV)
  ENABLED = TRUE
  COMMENT = 'Openflow DEV runtime access to Sales PostgreSQL';

GRANT USAGE ON INTEGRATION EAI_PG_SALES_DEV TO ROLE OF_RT_SALES_DEV;

-------------------------------------------------------------------
-- 5. Compute pool (OPENFLOW_ADMIN) -- VERIFY
-------------------------------------------------------------------
-- The quickstart selects an existing compute pool when creating a runtime.
-- Confirm whether the runtime role or creating role needs USAGE on the pool:
-- GRANT USAGE ON COMPUTE POOL <pool_name> TO ROLE OF_RT_SALES_DEV;

-------------------------------------------------------------------
-- 6. Verification
-------------------------------------------------------------------
SHOW GRANTS TO ROLE OPENFLOW_ADMIN;
SHOW GRANTS TO ROLE OF_RT_SALES_DEV;
SHOW GRANTS ON INTEGRATION EAI_PG_SALES_DEV;
DESC NETWORK RULE OPENFLOW_ADMIN_DB.NETWORKS.NR_PG_SALES_DEV;
```

### Assumptions to verify before rollout
1. **Who can create runtimes.** Snowflake's quickstart performs deployment and runtime creation as the admin role. Whether a narrower engineer role can create runtimes was not confirmed. If not, the fallback is: admin creates runtimes; engineers only build and operate flows on the canvas.
2. **Compute pool privileges** for runtime creation (block 5).
3. **Connector-specific privileges** in the destination (schema and table creation, ownership behavior). Check each connector's documentation.
4. **Availability.** The Snowflake-hosted deployment type was described as a preview feature in the quickstart; confirm status for your account and cloud.

---

## 3. Runbook (generic)

### A. Onboard a new source (admin + engineer)

| # | Owner | Step |
|---|---|---|
| 1 | Engineer | Submit request: source, data owner, expected volume, frequency, target domain, DEV or PROD. |
| 2 | Source owner | Prepare the source (service account, replication or read access, network reachability). For CDC, confirm replication prerequisites. |
| 3 | Admin | Create the network rule and external access integration for the source; grant it to the runtime role. |
| 4 | Admin | Confirm landing database, warehouse, and runtime role exist for the domain (see grant script). |
| 5 | Admin/Engineer | Create the runtime (Snowsight: Openflow > Runtimes) with the runtime role, integration, and compute pool. Wait for status `ACTIVE`. |

### B. Build and test in DEV (engineer)
1. Open the runtime canvas and add the connector.
2. Enter connection parameters; store credentials per your secrets policy, not in flow notes or comments.
3. Start with a small table or folder subset.
4. Confirm data lands in the expected schema and row counts match the source.
5. Test failure paths: stop the source, revoke a credential, confirm the flow surfaces an error rather than silently stalling.
6. Record the flow's purpose, owner, source, and schedule in your team catalog.

### C. Promote to PROD (admin)
1. Engineer requests review with: flow export or version reference, source details, expected volume, and rollback plan.
2. Admin reviews scope (tables/folders), destination, and network access.
3. Admin creates PROD roles, integration, and runtime, then deploys the flow.
4. Start with a limited scope, verify counts, then expand.
5. Enable monitoring and alerting before declaring the pipeline live.

### D. Routine checks
- **Daily:** Runtime status is `ACTIVE`; flows show no persistent errors or backed-up queues; expected data arrived.
- **Weekly:** Review compute pool and warehouse credit use against resource monitor quotas; review event table errors.
- **Monthly:** Review who holds engineer and admin roles; review network rules for unused entries; check for connector or runtime updates.

### E. Troubleshooting

| Symptom | Check first |
|---|---|
| Deployment stuck in `CREATING` or `ERROR` | `SHOW GRANTS TO ROLE OPENFLOW_ADMIN`; deployment event table logs if enabled |
| Connector cannot reach source | Network rule host and port; integration `ENABLED = TRUE`; usage granted to the runtime role; source-side firewall allows Snowflake egress |
| "Insufficient privileges" | `SELECT CURRENT_ROLE()`; grants on the runtime role for database, warehouse, integration |
| Data not appearing | Flow queue and processor errors on the canvas; destination schema and grants; warehouse suspended by resource monitor |
| Unexpected cost | Runtimes left running with idle flows; oversized warehouse; resource monitor thresholds |

### F. Change, rollback, and decommission
- **Before changing a PROD flow:** export or otherwise back up the current version.
- **Rollback:** redeploy the last known-good flow version, then confirm counts against the source.
- **Decommission:** stop the flow, back up the flow definition, remove runtimes and deployments through Snowsight (so associated resources are cleaned up), then drop integrations, network rules, and unused roles. Do not drop landing data without owner sign-off.

### G. Access reviews and offboarding
- Remove `OF_ENGINEER_*` from departing users; rotate any source credentials they had access to.
- Re-certify admin role membership at least quarterly.
