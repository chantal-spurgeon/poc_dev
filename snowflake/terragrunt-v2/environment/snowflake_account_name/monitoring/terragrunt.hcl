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

  # Event table view the telemetry rollup reads (find yours with
  # SHOW PARAMETERS LIKE 'EVENT_TABLE' IN ACCOUNT; this is the default one).
  event_view = "SNOWFLAKE.TELEMETRY.EVENTS_VIEW"

  retention_days   = 90    # rows older than this are deleted by the rollup/capture tasks
  snapshot_minutes = 10    # keep equal to the capture schedules below (used to turn counts into hours)
  idle_cpu_cores   = 0.05  # V_IDLE_BUT_RUNNING_24H: below this max CPU a running service counts as idle

  # Optional auto-suspend of one compute pool overnight. null = not created.
  # Set to a pool name to create the task (it is created STOPPED, see below).
  # It SUSPENDS A SHARED POOL when nothing was busy for 30 minutes, so read the
  # README section on it before turning it on.
  idle_suspend_pool = null

  sql_vars = {
    monitor_schema   = local.schema
    event_view       = local.event_view
    retention_days   = local.retention_days
    snapshot_minutes = local.snapshot_minutes
    idle_cpu_cores   = local.idle_cpu_cores
    pool_name        = local.idle_suspend_pool == null ? "" : local.idle_suspend_pool
  }

  # The suspend task as a one-entry map, so it can be filtered out when unused.
  suspend_task = {
    "${local.schema}.SUSPEND_POOL_IF_IDLE" = {
      comment   = "Evenings: suspend the pool if no container CPU was busy and no job ran in the last 30 minutes"
      statement = trimspace(templatefile("${local.sql_dir}/suspend_pool_if_idle.sql.tftpl", local.sql_vars))
      warehouse = local.warehouse
      schedule  = { using_cron = "0,30 20-23 * * * America/New_York" }
      started   = false
    }
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

    "${local.schema}.POOL_CHANGE_LOG" = {
      comment = "Manual log of compute pool setting changes, written before/after each change (rollback aid)"
      columns = [
        { name = "CHANGED_AT", type = "TIMESTAMP_LTZ(9)", default_expression = "CURRENT_TIMESTAMP()" },
        { name = "POOL_NAME", type = "VARCHAR(16777216)" },
        { name = "SETTING", type = "VARCHAR(16777216)" },
        { name = "OLD_VALUE", type = "VARCHAR(16777216)" },
        { name = "NEW_VALUE", type = "VARCHAR(16777216)" },
        { name = "NOTE", type = "VARCHAR(16777216)" },
      ]
    }

    "${local.schema}.UTIL_HOURLY" = {
      comment = "Hourly CPU and memory percentiles per pool and service (filled by ROLLUP_POOL_TELEMETRY)"
      columns = [
        { name = "HOUR", type = "TIMESTAMP_LTZ(9)" },
        { name = "POOL_NAME", type = "VARCHAR(16777216)" },
        { name = "SERVICE", type = "VARCHAR(16777216)" },
        { name = "METRIC", type = "VARCHAR(16777216)" },
        { name = "P50", type = "FLOAT" },
        { name = "P95", type = "FLOAT" },
        { name = "MAX_VAL", type = "FLOAT" },
      ]
    }

    "${local.schema}.ERRORS_HOURLY" = {
      comment = "Hourly count of error-like log lines per pool and service (filled by ROLLUP_POOL_TELEMETRY)"
      columns = [
        { name = "HOUR", type = "TIMESTAMP_LTZ(9)" },
        { name = "POOL_NAME", type = "VARCHAR(16777216)" },
        { name = "SERVICE", type = "VARCHAR(16777216)" },
        { name = "ERROR_LINES", type = "NUMBER(38,0)" },
      ]
    }

    "${local.schema}.SERVICE_EVENTS_HOURLY" = {
      comment = "Hourly count of service events by name (filled by ROLLUP_POOL_TELEMETRY)"
      columns = [
        { name = "HOUR", type = "TIMESTAMP_LTZ(9)" },
        { name = "POOL_NAME", type = "VARCHAR(16777216)" },
        { name = "SERVICE", type = "VARCHAR(16777216)" },
        { name = "EVENT_NAME", type = "VARCHAR(16777216)" },
        { name = "EVENTS", type = "NUMBER(38,0)" },
      ]
    }

    "${local.schema}.SERVICE_STATE_LOG" = {
      comment = "Snapshot of SHOW SERVICES IN ACCOUNT every 10 minutes (filled by CAPTURE_SERVICE_STATE)"
      columns = [
        { name = "CAPTURED_AT", type = "TIMESTAMP_LTZ(9)" },
        { name = "SERVICE_NAME", type = "VARCHAR(16777216)" },
        { name = "DATABASE_NAME", type = "VARCHAR(16777216)" },
        { name = "SCHEMA_NAME", type = "VARCHAR(16777216)" },
        { name = "OWNER", type = "VARCHAR(16777216)" },
        { name = "COMPUTE_POOL", type = "VARCHAR(16777216)" },
        { name = "STATUS", type = "VARCHAR(16777216)" },
        { name = "IS_JOB", type = "BOOLEAN" },
        { name = "CURRENT_INSTANCES", type = "NUMBER(38,0)" },
        { name = "MIN_INSTANCES", type = "NUMBER(38,0)" },
        { name = "MAX_INSTANCES", type = "NUMBER(38,0)" },
        { name = "AUTO_RESUME", type = "BOOLEAN" },
        { name = "AUTO_SUSPEND_SECS", type = "NUMBER(38,0)" },
        { name = "CREATED_ON", type = "TIMESTAMP_LTZ(9)" },
        { name = "RESUMED_ON", type = "TIMESTAMP_LTZ(9)" },
        { name = "SUSPENDED_ON", type = "TIMESTAMP_LTZ(9)" },
        { name = "MANAGING_OBJECT_DOMAIN", type = "VARCHAR(16777216)", comment = "Set when another object, such as a Streamlit app, manages the service" },
        { name = "MANAGING_OBJECT_NAME", type = "VARCHAR(16777216)" },
        { name = "COMMENT", type = "VARCHAR(16777216)" },
      ]
    }

    "${local.schema}.POOL_SUSPEND_LOG" = {
      comment = "One row per run of SUSPEND_POOL_IF_IDLE: what it saw and whether it suspended the pool"
      columns = [
        { name = "CHECKED_AT", type = "TIMESTAMP_LTZ(9)" },
        { name = "POOL_NAME", type = "VARCHAR(16777216)" },
        { name = "SAMPLES", type = "NUMBER(38,0)" },
        { name = "BUSY", type = "NUMBER(38,0)" },
        { name = "JOBS", type = "NUMBER(38,0)" },
        { name = "ACTION", type = "VARCHAR(16777216)" },
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

    "${local.schema}.V_HEADROOM_7D" = {
      comment   = "Peak-hour CPU/memory headroom per service, last 7 days (compare p95 to requested/limit)"
      statement = trimspace(templatefile("${local.sql_dir}/v_headroom_7d.sql.tftpl", local.sql_vars))
    }

    "${local.schema}.V_POOL_KEEPERS_NOW" = {
      comment   = "Latest snapshot: which services are holding each compute pool open"
      statement = trimspace(templatefile("${local.sql_dir}/v_pool_keepers_now.sql.tftpl", local.sql_vars))
    }

    "${local.schema}.V_SERVICE_RUNNING_HOURS_DAILY" = {
      comment   = "Approximate hours each service spent RUNNING per day (snapshot count x interval)"
      statement = trimspace(templatefile("${local.sql_dir}/v_service_running_hours_daily.sql.tftpl", local.sql_vars))
    }

    "${local.schema}.V_IDLE_BUT_RUNNING_24H" = {
      comment   = "Services RUNNING in the last 24h while container CPU stayed near zero"
      statement = trimspace(templatefile("${local.sql_dir}/v_idle_but_running_24h.sql.tftpl", local.sql_vars))
    }

    "${local.schema}.V_DAILY_SCORECARD" = {
      comment   = "One daily scorecard per pool: credits, suspends/resumes, capacity pressure, errors"
      statement = trimspace(templatefile("${local.sql_dir}/v_daily_scorecard.sql.tftpl", local.sql_vars))
      after_other_views = true # reads other views in this list
    }

    "${local.schema}.V_SERVICE_PCT_OF_DAY" = {
      comment   = "Share of each day a service was RUNNING (about 100 = it alone keeps the pool awake)"
      statement = trimspace(templatefile("${local.sql_dir}/v_service_pct_of_day.sql.tftpl", local.sql_vars))
      after_other_views = true # reads other views in this list
    }

    "${local.schema}.V_DAILY_KEEPERS" = {
      comment   = "Per day and pool: how many services ran 20h+ and how many have no auto-suspend"
      statement = trimspace(templatefile("${local.sql_dir}/v_daily_keepers.sql.tftpl", local.sql_vars))
      after_other_views = true # reads other views in this list
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
  tasks = merge({

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

    "${local.schema}.ROLLUP_POOL_TELEMETRY" = {
      comment   = "Hourly (at :05): roll the last completed hour of event-table metrics, errors and events into small tables"
      statement = trimspace(templatefile("${local.sql_dir}/rollup_pool_telemetry.sql.tftpl", local.sql_vars))
      warehouse = local.warehouse
      schedule  = { using_cron = "5 * * * * America/Chicago" }
      started   = true
    }

    "${local.schema}.CAPTURE_SERVICE_STATE" = {
      comment   = "Every 10 minutes: snapshot SHOW SERVICES IN ACCOUNT into SERVICE_STATE_LOG"
      statement = trimspace(templatefile("${local.sql_dir}/capture_service_state.sql.tftpl", local.sql_vars))
      warehouse = local.warehouse
      schedule  = { minutes = 10 }
      started   = true
    }
  },

  # Only when idle_suspend_pool is set at the top of this file.
  { for k, v in local.suspend_task : k => v if local.idle_suspend_pool != null })
}
