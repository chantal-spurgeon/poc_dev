# live/snowflake_account_name/rbac/terragrunt.hcl

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}//snowflake/terragrunt"
}

dependencies {
  paths = ["../databases", "../integrations", "../users", "../warehouses"]
}

inputs = {
  account_roles = {
    "SYSADMIN" = {
      comment               = "Native Snowflake system administrator role"
      granted_roles         = ["PRODUCER8", "SECURITY_ADMIN_CUSTOM8"]
      granted_users         = []
      warehouse_privileges        = {}
      integration_privileges      = {}
      database_privileges         = {}
      schema_privileges           = {}
      all_table_privileges        = {}
      all_view_privileges         = {}
      all_procedure_privileges    = {}
      all_function_privileges     = {}
      all_task_privileges         = {}
      all_stage_privileges        = {}
      future_table_privileges     = {}
      future_view_privileges      = {}
      future_procedure_privileges = {}
      future_function_privileges  = {}
      future_task_privileges       = {}
      future_stage_privileges     = {}
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

    "SECURITY_ADMIN_CUSTOM8" = {
      comment       = "Custom operational role designed to monitor security metrics"
      granted_roles = ["SECURITYADMIN"]
      granted_users = ["BANGCHAN8"]
      warehouse_privileges        = {}
      integration_privileges      = {}
      database_privileges         = {}
      schema_privileges           = {}
      all_table_privileges        = {}
      all_view_privileges         = {}
      all_procedure_privileges    = {}
      all_function_privileges     = {}
      all_task_privileges         = {}
      all_stage_privileges        = {}
      future_table_privileges     = {}
      future_view_privileges      = {}
      future_procedure_privileges = {}
      future_function_privileges  = {}
      future_task_privileges       = {}
      future_stage_privileges     = {}
    }
  }
}
