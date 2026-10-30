# environment/snowflake_account_name/rbac/terragrunt.hcl

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}//snowflake/terragrunt-v2"
}

dependencies {
  paths = ["../databases", "../integrations", "../users", "../warehouses"]
}

inputs = {
  account_roles = {
    "SYSADMIN" = {
      comment               = "Native Snowflake system administrator role"
      granted_roles         = ["PRODUCER8", "SECURITY_ADMIN_CUSTOM8", "MONITOR_ADMIN"]
      granted_users         = []
    },

    "PRODUCER8" = {
      comment       = "Role for 3RACHA"
      granted_roles = []
      granted_users = ["BANGCHAN8"]

      warehouse_privileges   = { "PRODUCER8_WH" = ["USAGE", "OPERATE", "MONITOR"] }
      integration_privileges = { "AWS_S3_DATA_LAKE8" = ["USAGE"] }
      database_privileges    = { "DB_STRAY_KIDS8" = ["USAGE"] }

      schema_privileges = {
        "DB_STRAY_KIDS8.CHANS_LAPTOP" = ["OWNERSHIP", "USAGE"],
        "DB_STRAY_KIDS8.COMEBACKS"    = ["USAGE", "MODIFY", "CREATE TABLE"],
      }

      all_table_privileges     = { "DB_STRAY_KIDS8.COMEBACKS" = ["SELECT", "INSERT", "DELETE", "UPDATE"] }
      all_view_privileges      = { "DB_STRAY_KIDS8.COMEBACKS" = ["SELECT", "INSERT", "DELETE", "UPDATE"] }
      all_procedure_privileges = { "DB_STRAY_KIDS8.COMEBACKS" = ["USAGE"] }
      all_function_privileges  = { "DB_STRAY_KIDS8.COMEBACKS" = ["USAGE"] }
      all_task_privileges      = { "DB_STRAY_KIDS8.COMEBACKS" = ["OWNERSHIP"] }
      all_stage_privileges     = { "DB_STRAY_KIDS8.COMEBACKS" = ["READ", "WRITE"] }

      future_table_privileges     = { "DB_STRAY_KIDS8.COMEBACKS" = ["SELECT", "INSERT", "DELETE", "UPDATE"] }
      future_view_privileges      = { "DB_STRAY_KIDS8.COMEBACKS" = ["SELECT", "INSERT", "DELETE", "UPDATE"] }
      future_procedure_privileges = { "DB_STRAY_KIDS8.COMEBACKS" = ["USAGE"] }
      future_function_privileges  = { "DB_STRAY_KIDS8.COMEBACKS" = ["USAGE"] }
      future_task_privileges      = { "DB_STRAY_KIDS8.COMEBACKS" = ["OWNERSHIP"] }
      future_stage_privileges     = { "DB_STRAY_KIDS8.COMEBACKS" = ["READ", "WRITE"] }
    },

    # Owns the monitoring tables, views, procedures and tasks, and is the role the
    # monitoring unit signs in with. Everything it needs is listed here and nothing
    # more. Add the people who should be able to run that unit to granted_users.
    "MONITOR_ADMIN" = {
      comment            = "Owner of the standard monitoring objects"
      granted_users      = ["BANGCHAN8"]
      account_privileges = ["EXECUTE TASK", "EXECUTE MANAGED TASK"]

      database_privileges = {
        "ADMIN_DB" = ["USAGE"]
        "SNOWFLAKE" = ["IMPORTED PRIVILEGES"] # reads ACCOUNT_USAGE (query history, credits)
      }
      schema_privileges = {
        "ADMIN_DB.FINOPS" = ["USAGE", "CREATE TABLE", "CREATE VIEW", "CREATE PROCEDURE", "CREATE TASK"]
      }
    },

    "SECURITY_ADMIN_CUSTOM8" = {
      comment       = "Custom operational role designed to monitor security metrics"
      # SNOWFLAKE.SECURITY_VIEWER lets the role see security views without being able to change anything.
      # (It used to inherit SECURITYADMIN, which gave SYSADMIN and BANGCHAN8 full security admin.)
      granted_roles          = []
      granted_database_roles = ["SNOWFLAKE.SECURITY_VIEWER"]
      granted_users = ["BANGCHAN8"]
    }
  }
}
