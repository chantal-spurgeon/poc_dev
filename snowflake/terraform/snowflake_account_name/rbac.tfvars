account_roles = {
  "producer" = {
    comment       = "Role for 3RACHA"
    granted_roles = [] #Optional - roles that are granted this role
    granted_users = ["BANGCHAN","HAN","CHANGBIN"]

    warehouse_privileges = {
      "PRODUCER_WH" = ["USAGE","OPERATE","MONITOR"],
    }
    integration_privileges = {
      "AWS_S3_DATA_LAKE" = ["USAGE"],
    }
    database_privileges = {
      "DB_STRAY_KIDS" = ["OWNERSHIP"],
    }
    schema_privileges = {
      "DB_STRAY_KIDS.CHANS_LAPTOP" = ["OWNERSHIP"],
      "DB_STRAY_KIDS.COMBACKS"    = ["USAGE", "MODIFY", "CREATE TABLE"],
    }
    # Automatically grant SELECT on any table or view added to CORE_MART later
    future_table_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["SELECT","INSERT","DELETE","UPDATE"],
    }
    future_view_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["SELECT","INSERT","DELETE","UPDATE"],
    }
    # Target ALL existing tables and views
    all_table_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["SELECT","INSERT","DELETE","UPDATE"],
    }
    all_view_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["SELECT","INSERT","DELETE","UPDATE"],
    }
    all_procedure_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["USAGE"],
    }
    future_procedure_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["USAGE"],
    }
    all_function_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["USAGE"],
    }
    future_function_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["USAGE"],
    }
    all_task_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["OWNERSHIP"],
    }
    future_task_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["OWNERSHIP"],
    }
    all_stage_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["READ", "WRITE"],
    }
    future_stage_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["READ", "WRITE"],
    }
  },

  # Administrative system role
  "security_admin_custom" = {
    comment       = "Custom operational role designed to monitor security metrics"
    granted_roles = []
    granted_users = ["BANGCHAN"]
  },

}
