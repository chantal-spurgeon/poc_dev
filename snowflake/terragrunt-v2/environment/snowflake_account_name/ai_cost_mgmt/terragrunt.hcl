# environment/snowflake_account_name/ai_cost_mgmt/terragrunt.hcl
#
# AI cost management: monthly AI budgets per tier role (hourly revoke, monthly
# reset), CoCo daily-limit exceptions, and the backend of the self-service AI
# usage dashboard. Same pattern as the monitoring unit: tables, views,
# procedures and tasks, with the SQL in sql/*.sql.tftpl.
#
# Needs, from the other units:
#   databases  AI_COST_MGMT with a TRANSIENT DASHBOARD schema (PUBLIC exists by
#              default)
#   rbac       the AI_COST_ADMIN role (this unit signs in as it, see account.hcl)
#
# Needs, granted BY HAND (not managed here, see README "AI cost management unit"):
#   - AI_COST_ADMIN must own the tier roles AI_EXPLORER and AI_DATA_SCIENCE, so
#     the enforcement and reset procedures can revoke and grant them
#   - AI_COST_ADMIN must be able to ALTER USER ... SET/UNSET the three CoCo
#     daily-limit parameters, for the exception procedures
#   - the exception UI role's USAGE on two procedures and SELECT on one view
#   - the Streamlit app owner's SELECT on the three dashboard tables
#
# EXISTING PROD OBJECTS. AI_COST_MGMT, AI_ROLE_BUDGETS, AI_ENFORCEMENT_LOG and
# the CoCo exception objects already exist in prod. Import them before the first
# apply there (README), or Terraform will try to create them and fail.

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
  # Where the objects live. Everything below is written against these.
  ai_schema   = "AI_COST_MGMT.PUBLIC"    # budgets, enforcement log, enforcement/reset/refresh procedures
  dash_schema = "AI_COST_MGMT.DASHBOARD" # TRANSIENT schema: the three dashboard tables (transient, no Fail-safe)

  # CoCo exception objects. The original script used admin_db.util as a
  # placeholder. Set this to where they are deployed in prod before importing.
  exceptions_schema = "AI_COST_MGMT.PUBLIC"

  # null = serverless tasks. Set a warehouse name to run the tasks on it instead
  # (then add USAGE on it to AI_COST_ADMIN in rbac).
  warehouse = null

  # Account-level CoCo daily limit (the three CORTEX_CODE_*_DAILY_EST_CREDIT_LIMIT_PER_USER
  # parameters). The dashboard shows it to users without an exception.
  coco_default_daily = 10

  # Months of usage history the dashboard keeps in AI_DASH_USAGE_DAILY, including
  # the current month (the Activity tab can look back this far). 2 = the standard
  # version (previous + current month); 6 = the retention version. After the first
  # apply, or after raising it, load the older months once:
  #   CALL AI_COST_MGMT.PUBLIC.REFRESH_AI_USAGE_DASHBOARD(TRUE);
  dash_keep_months = 6

  # ENFORCEMENT SWITCH. false = the enforcement and reset tasks are created
  # suspended. Revoking roles is not something a fresh deployment should start
  # doing on its own: run the procedures by hand, check AI_ENFORCEMENT_LOG, then
  # set true and apply. In prod (after import) set this to match the tasks' state.
  enforcement_started = false

  sql_dir = "${get_terragrunt_dir()}/sql"

  sql_vars = {
    ai_schema          = local.ai_schema
    dash_schema        = local.dash_schema
    exceptions_schema  = local.exceptions_schema
    coco_default_daily = local.coco_default_daily
    dash_keep_months   = local.dash_keep_months
  }
}

inputs = {

  # ---------------------------------------------------------------------------
  # Tables. Types are written the way Snowflake reports them so the first plan
  # shows no difference. The two prod tables marked CHECK were not available to
  # read: compare with DESC TABLE before importing and adjust.
  # ---------------------------------------------------------------------------
  tables = {

    # --- budgets and enforcement (prod) ---

    "${local.ai_schema}.AI_ROLE_BUDGETS" = {
      comment = "Monthly AI credit limit per tier role. Rows are data: insert them in SQL, not here."
      columns = [
        { name = "ROLE_NAME", type = "VARCHAR(16777216)" },            # CHECK against prod
        { name = "MONTHLY_CREDIT_LIMIT", type = "NUMBER(38,2)" },      # CHECK against prod
      ]
    }

    "${local.ai_schema}.AI_ENFORCEMENT_LOG" = {
      comment = "One row per revoke (ENFORCE_CORTEX_AI_LIMITS) and per re-grant (RESET_ALL_AI_ACCESS)"
      columns = [
        { name = "USER_NAME", type = "VARCHAR(16777216)" },            # CHECK against prod
        { name = "TIER_ROLE", type = "VARCHAR(16777216)" },
        { name = "ACTION", type = "VARCHAR(16777216)", comment = "REVOKED or RESET" },
        { name = "CREDITS_USED", type = "NUMBER(38,6)" },
        { name = "CREDIT_LIMIT", type = "NUMBER(38,6)" },
        # The procedures don't insert this column; it fills from the default.
        # The dashboard refresh reads it. CHECK the real name in prod.
        { name = "LOGGED_AT", type = "TIMESTAMP_LTZ(9)", default_expression = "CURRENT_TIMESTAMP()" },
      ]
    }

    # --- dashboard backend (transient schema; Time Travel off) ---

    "${local.dash_schema}.AI_DASH_USAGE_DAILY" = {
      comment                  = "Dashboard: credits per user/day/service/detail, dash_keep_months of history"
      data_retention_time_days = 0
      columns = [
        { name = "USAGE_DATE", type = "DATE" },
        { name = "USER_NAME", type = "VARCHAR(16777216)" },
        { name = "SOURCE", type = "VARCHAR(16777216)" },
        { name = "DETAIL", type = "VARCHAR(16777216)", comment = "Function and model (AI Functions), model (REST API)" },
        { name = "CREDITS", type = "NUMBER(38,6)" },
        { name = "COUNTS_TOWARD_BUDGET", type = "BOOLEAN", comment = "FALSE = shown but not counted by enforcement" },
        { name = "REFRESHED_AT", type = "TIMESTAMP_LTZ(9)" },
      ]
    }

    "${local.dash_schema}.AI_DASH_USER_STATUS" = {
      comment                  = "Dashboard: one row per user on the tier role governing their access (overwritten hourly)"
      data_retention_time_days = 0
      columns = [
        { name = "USER_NAME", type = "VARCHAR(16777216)" },
        { name = "TIER_ROLE", type = "VARCHAR(16777216)" },
        { name = "MONTHLY_CREDIT_LIMIT", type = "NUMBER(38,6)" },
        { name = "CREDITS_USED", type = "NUMBER(38,6)" },
        { name = "STATUS", type = "VARCHAR(16777216)", comment = "ACTIVE, OVER_LIMIT or REVOKED" },
        { name = "REVOKED_AT", type = "TIMESTAMP_LTZ(9)" },
        { name = "MONTH_START", type = "TIMESTAMP_LTZ(9)" },
        { name = "REFRESHED_AT", type = "TIMESTAMP_LTZ(9)" },
      ]
    }

    "${local.dash_schema}.AI_DASH_COCO_24H" = {
      comment                  = "Dashboard: CoCo credits in the last 24h per user and interface vs daily limit (overwritten hourly)"
      data_retention_time_days = 0
      columns = [
        { name = "USER_NAME", type = "VARCHAR(16777216)" },
        { name = "INTERFACE", type = "VARCHAR(16777216)" },
        { name = "CREDITS_24H", type = "NUMBER(38,6)" },
        { name = "DAILY_LIMIT", type = "NUMBER(38,0)", comment = "-1 = unlimited" },
        { name = "EXCEPTION_EXPIRES_AT", type = "TIMESTAMP_LTZ(9)" },
        { name = "REFRESHED_AT", type = "TIMESTAMP_LTZ(9)" },
      ]
    }

    # --- CoCo daily-limit exceptions (prod) ---

    "${local.exceptions_schema}.COCO_LIMIT_EXCEPTION_LOG" = {
      comment = "One row per user per approved CoCo limit exception (audit trail and source of truth)"
      columns = [
        { name = "EXCEPTION_ID", type = "NUMBER(38,0)", identity = { start = 1, step = 1 } },
        { name = "REQUEST_ID", type = "VARCHAR(16777216)", comment = "One per Accept click" },
        { name = "TARGET_TYPE", type = "VARCHAR(16777216)", comment = "USER or ROLE" },
        { name = "TARGET_NAME", type = "VARCHAR(16777216)" },
        { name = "USER_NAME", type = "VARCHAR(16777216)", comment = "The user this row's override applies to" },
        { name = "LIMIT_VALUE", type = "NUMBER(38,0)", comment = "-1 = unlimited, n = n credits per 24h" },
        { name = "APPROVED_BY", type = "VARCHAR(16777216)" },
        { name = "REASON", type = "VARCHAR(16777216)" },
        { name = "GRANTED_AT", type = "TIMESTAMP_LTZ(9)" },
        { name = "EXPIRES_AT", type = "TIMESTAMP_LTZ(9)" },
        { name = "STATUS", type = "VARCHAR(16777216)", comment = "ACTIVE, EXPIRED or REVOKED" },
        { name = "ENDED_AT", type = "TIMESTAMP_LTZ(9)" },
        { name = "ENDED_BY", type = "VARCHAR(16777216)", comment = "Revoker name, or EXPIRY_TASK" },
      ]
    }
  }

  # ---------------------------------------------------------------------------
  # Views
  # ---------------------------------------------------------------------------
  views = {
    "${local.exceptions_schema}.COCO_LIMIT_EXCEPTIONS_ACTIVE" = {
      comment   = "Current CoCo limit exceptions, one row per user, with days remaining (for the UI)"
      statement = trimspace(templatefile("${local.sql_dir}/v_coco_limit_exceptions_active.sql.tftpl", local.sql_vars))
    }
  }

  # ---------------------------------------------------------------------------
  # Procedures. Argument names are UPPER CASE (see variables.tf).
  # ---------------------------------------------------------------------------
  procedures = {

    # --- budgets and enforcement (as in prod) ---

    "${local.ai_schema}.ENFORCE_CORTEX_AI_LIMITS" = {
      comment    = "Revokes the tier role from users over their monthly AI budget and logs it"
      returns    = "VARCHAR"
      execute_as = "CALLER"
      body       = trimspace(templatefile("${local.sql_dir}/enforce_cortex_ai_limits.sql.tftpl", local.sql_vars))
    }

    "${local.ai_schema}.RESET_ALL_AI_ACCESS" = {
      comment    = "Monthly: grants a tier role to every eligible user without one, and logs it"
      returns    = "VARCHAR"
      execute_as = "CALLER"
      body       = trimspace(templatefile("${local.sql_dir}/reset_all_ai_access.sql.tftpl", local.sql_vars))
    }

    # --- dashboard backend ---

    "${local.ai_schema}.REFRESH_AI_USAGE_DASHBOARD" = {
      comment    = "Hourly: rebuilds the three dashboard tables (read-only on enforcement). P_BACKFILL = TRUE reloads the full retention period"
      arguments  = [{ name = "P_BACKFILL", type = "BOOLEAN", default = "FALSE" }]
      returns    = "VARCHAR"
      execute_as = "CALLER"
      body       = trimspace(templatefile("${local.sql_dir}/refresh_ai_usage_dashboard.sql.tftpl", local.sql_vars))
    }

    # --- CoCo daily-limit exceptions ---

    "${local.exceptions_schema}.COCO_APPLY_EFFECTIVE_LIMIT" = {
      comment    = "Internal: applies one user's effective CoCo limit from their active exceptions. Do not grant to the UI."
      arguments  = [{ name = "P_USER", type = "VARCHAR" }]
      returns    = "VARCHAR"
      execute_as = "OWNER"
      body       = trimspace(templatefile("${local.sql_dir}/coco_apply_effective_limit.sql.tftpl", local.sql_vars))
    }

    "${local.exceptions_schema}.COCO_GRANT_LIMIT_EXCEPTION" = {
      comment = "Called by the UI's Accept button: grants a CoCo limit exception to a user or every user in a role"
      arguments = [
        { name = "P_TARGET_TYPE", type = "VARCHAR" },
        { name = "P_TARGET_NAME", type = "VARCHAR" },
        { name = "P_LIMIT", type = "NUMBER" },
        { name = "P_APPROVED_BY", type = "VARCHAR" },
        { name = "P_REASON", type = "VARCHAR", default = "NULL" },
        { name = "P_DAYS", type = "NUMBER", default = "30" },
      ]
      returns    = "VARIANT"
      execute_as = "OWNER"
      body       = trimspace(templatefile("${local.sql_dir}/coco_grant_limit_exception.sql.tftpl", local.sql_vars))
    }

    "${local.exceptions_schema}.COCO_REVOKE_LIMIT_EXCEPTION" = {
      comment = "Optional early end of one approved request"
      arguments = [
        { name = "P_REQUEST_ID", type = "VARCHAR" },
        { name = "P_REVOKED_BY", type = "VARCHAR" },
      ]
      returns    = "VARIANT"
      execute_as = "OWNER"
      body       = trimspace(templatefile("${local.sql_dir}/coco_revoke_limit_exception.sql.tftpl", local.sql_vars))
    }

    "${local.exceptions_schema}.COCO_EXPIRE_LIMIT_EXCEPTIONS" = {
      comment    = "Called by the expiry task: ends exceptions past their expiry and recalculates those users"
      returns    = "VARCHAR"
      execute_as = "OWNER"
      body       = trimspace(templatefile("${local.sql_dir}/coco_expire_limit_exceptions.sql.tftpl", local.sql_vars))
    }
  }

  # ---------------------------------------------------------------------------
  # Tasks. started = true means resumed (running on its schedule).
  # Session timezone: the enforcement, reset and refresh procedures take "this
  # month" from the task's session TIMEZONE (account default unless set), not
  # from the cron timezone. Keep all three on the same TIMEZONE.
  # ---------------------------------------------------------------------------
  tasks = {

    # CHECK the prod task names and schedules before importing.
    "${local.ai_schema}.ENFORCE_CORTEX_AI_LIMITS_TASK" = {
      comment   = "Hourly: revoke tier roles from users over their monthly AI budget"
      statement = "CALL ${local.ai_schema}.ENFORCE_CORTEX_AI_LIMITS();"
      warehouse = local.warehouse
      schedule  = { using_cron = "0 * * * * America/Chicago" }
      started   = local.enforcement_started
    }

    "${local.ai_schema}.RESET_ALL_AI_ACCESS_TASK" = {
      comment   = "1st of each month: re-grant tier roles"
      statement = "CALL ${local.ai_schema}.RESET_ALL_AI_ACCESS();"
      warehouse = local.warehouse
      schedule  = { using_cron = "0 0 1 * * America/Chicago" }
      started   = local.enforcement_started
    }

    # A few minutes after enforcement, so a revoke shows up in the same hour.
    "${local.ai_schema}.REFRESH_AI_USAGE_DASHBOARD_TASK" = {
      comment   = "Hourly: refresh the AI usage dashboard tables"
      statement = "CALL ${local.ai_schema}.REFRESH_AI_USAGE_DASHBOARD();"
      warehouse = local.warehouse
      schedule  = { using_cron = "15 * * * * America/Chicago" }
      started   = true
    }

    "${local.exceptions_schema}.COCO_EXPIRE_LIMIT_EXCEPTIONS_TASK" = {
      comment   = "Hourly: end CoCo credit limit exceptions past their expiry date"
      statement = "CALL ${local.exceptions_schema}.COCO_EXPIRE_LIMIT_EXCEPTIONS();"
      warehouse = local.warehouse
      schedule  = { using_cron = "5 * * * * America/Chicago" }
      started   = true
    }
  }
}
