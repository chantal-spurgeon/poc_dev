# environment/snowflake_account_name/monitoring/terragrunt.hcl
#
# The standard monitoring set: log tables, report views, a refresh procedure and
# the tasks that fill them. Copy this folder (with sql/) to a new account folder to
# get the same monitoring there; only the locals below normally change.
#
# Needs, from the other units:
#   databases  ADMIN_DB with a FINOPS schema
#   rbac       the MONITOR_ADMIN role: CREATE TABLE/VIEW/PROCEDURE/TASK on that
#              schema, EXECUTE TASK, EXECUTE MANAGED TASK, IMPORTED PRIVILEGES on
#              SNOWFLAKE (this unit signs in as MONITOR_ADMIN, see account.hcl)

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}//snowflake/terragrunt-v2"
}

dependencies {
  paths = ["../databases", "../rbac"]
}

locals {
  # Where the monitoring objects live. Everything below is written against this.
  schema = "ADMIN_DB.FINOPS"

  # null = serverless tasks (no warehouse to keep). Set a warehouse name to run
  # the tasks on it instead (then add USAGE on it to MONITOR_ADMIN in rbac).
  warehouse = null

  # The SQL lives in files so it can be read and diffed as SQL. ${monitor_schema}
  # in those files is replaced with local.schema, so no schema name is hard-coded.
  sql_dir = "${get_terragrunt_dir()}/sql"
  sql_vars = {
    monitor_schema = local.schema
  }
}

inputs = {

  # ---------------------------------------------------------------------------
  # Tables. Types are written the way Snowflake reports them (VARCHAR(16777216),
  # NUMBER(38,0), TIMESTAMP_LTZ(9)) so the first plan does not show a difference.
  # ---------------------------------------------------------------------------
  tables = {

    "${local.schema}.EGRESS_BY_ROLE_MONTHLY" = {
      comment = "Estimated egress cost per role per month (filled by REFRESH_EGRESS_BY_ROLE_MONTHLY)"
      columns = [
        { name = "MONTH", type = "DATE" },
        { name = "ROLE_NAME", type = "VARCHAR(16777216)" },
        { name = "TARGET_CLOUD", type = "VARCHAR(16777216)", comment = "Destination cloud of the unload" },
        { name = "TARGET_REGION", type = "VARCHAR(16777216)", comment = "Destination region, e.g. us-central1" },
        { name = "TARGET_REGION_ID", type = "VARCHAR(16777216)", comment = "e.g. GCP_US_CENTRAL1, comparable to CURRENT_REGION()" },
        { name = "UNLOAD_QUERIES", type = "NUMBER(38,0)" },
        { name = "GB_OUT", type = "NUMBER(18,2)" },
        { name = "RATE_PER_GB", type = "NUMBER(10,4)" },
        { name = "EST_COST_USD", type = "NUMBER(18,2)" },
        { name = "REFRESHED_AT", type = "TIMESTAMP_LTZ(9)" },
      ]
    }

    "${local.schema}.POOL_STATE_LOG" = {
      comment = "Snapshot of SHOW COMPUTE POOLS every 10 minutes (filled by CAPTURE_POOL_STATE)"
      columns = [
        { name = "CAPTURED_AT", type = "TIMESTAMP_LTZ(9)" },
        { name = "POOL_NAME", type = "VARCHAR(16777216)" },
        { name = "STATE", type = "VARCHAR(16777216)" },
        { name = "MIN_NODES", type = "NUMBER(38,0)" },
        { name = "MAX_NODES", type = "NUMBER(38,0)" },
        { name = "ACTIVE_NODES", type = "NUMBER(38,0)" },
        { name = "IDLE_NODES", type = "NUMBER(38,0)" },
        { name = "TARGET_NODES", type = "NUMBER(38,0)" },
        { name = "AUTO_SUSPEND_SECS", type = "NUMBER(38,0)" },
        { name = "INSTANCE_FAMILY", type = "VARCHAR(16777216)" },
        { name = "NUM_SERVICES", type = "NUMBER(38,0)" },
        { name = "NUM_JOBS", type = "NUMBER(38,0)" },
      ]
    }
  }

  # ---------------------------------------------------------------------------
  # Views (cheap: they read the small log tables or ACCOUNT_USAGE)
  # ---------------------------------------------------------------------------
  views = {

    "${local.schema}.V_EGRESS_REPORT" = {
      comment   = "Egress cost report with currency formatting (the table stays numeric)"
      statement = trimspace(templatefile("${local.sql_dir}/v_egress_report.sql.tftpl", local.sql_vars))
    }

    "${local.schema}.V_POOL_DAILY" = {
      comment   = "Per day and compute pool: suspends, resumes, time at max nodes"
      statement = trimspace(templatefile("${local.sql_dir}/v_pool_daily.sql.tftpl", local.sql_vars))
    }

    "${local.schema}.V_POOL_CREDITS_DAILY" = {
      comment   = "Credits per day and compute pool (ACCOUNT_USAGE lags by a few hours)"
      statement = trimspace(templatefile("${local.sql_dir}/v_pool_credits_daily.sql.tftpl", local.sql_vars))
    }
  }

  # ---------------------------------------------------------------------------
  # Procedures
  # ---------------------------------------------------------------------------
  procedures = {

    "${local.schema}.REFRESH_EGRESS_BY_ROLE_MONTHLY" = {
      comment    = "Recomputes this and last month of egress cost per role (idempotent)"
      returns    = "VARCHAR"
      execute_as = "OWNER"
      body       = trimspace(templatefile("${local.sql_dir}/refresh_egress_by_role_monthly.sql.tftpl", local.sql_vars))
    }
  }

  # ---------------------------------------------------------------------------
  # Tasks. started = true means the task is resumed, i.e. running on its schedule.
  # ---------------------------------------------------------------------------
  tasks = {

    "${local.schema}.REFRESH_EGRESS_BY_ROLE_MONTHLY_TASK" = {
      comment   = "Daily refresh of estimated egress cost per role per month"
      statement = "CALL ${local.schema}.REFRESH_EGRESS_BY_ROLE_MONTHLY();"
      warehouse = local.warehouse
      schedule  = { using_cron = "0 6 * * * America/Chicago" }
      started   = true
    }

    "${local.schema}.CAPTURE_POOL_STATE" = {
      comment   = "Every 10 minutes: snapshot SHOW COMPUTE POOLS into POOL_STATE_LOG"
      statement = trimspace(templatefile("${local.sql_dir}/capture_pool_state.sql.tftpl", local.sql_vars))
      warehouse = local.warehouse
      schedule  = { minutes = 10 }
      started   = true
    }
  }
}
