account_roles = {
  "SYSADMIN" = {
    # SYSADMIN is the parent that inherits the custom child roles
    comment       = "Native Snowflake system administrator role"
    granted_roles = ["PRODUCER",
                     "SECURITY_ADMIN_CUSTOM"]
    schema_privileges = {} # Pass an empty map so it satisfies the type schema
  },

  "PRODUCER" = {
    comment       = "Role for 3RACHA"
    granted_roles = [] #Optional - roles that are granted to this role
    granted_users = ["BANGCHAN"]

    warehouse_privileges = {
      "PRODUCER_WH" = ["USAGE","OPERATE","MONITOR"],
    }
    integration_privileges = {
      "AWS_S3_DATA_LAKE" = ["USAGE"],
    }
    database_privileges = {
      "DB_STRAY_KIDS" = ["USAGE"],
    }
    schema_privileges = {
      "DB_STRAY_KIDS.CHANS_LAPTOP" = ["OWNERSHIP","USAGE"],
      "DB_STRAY_KIDS.COMBACKS"    = ["USAGE", "MODIFY", "CREATE TABLE"],
    }
    # Schema ALL privileges
    all_table_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["SELECT","INSERT","DELETE","UPDATE"],
    }
    all_view_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["SELECT","INSERT","DELETE","UPDATE"],
    }
    all_procedure_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["USAGE"],
    }
    all_function_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["USAGE"],
    }
    all_task_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["OWNERSHIP"],
    }
    all_stage_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["READ", "WRITE"],
    }

    #Schema ALL privileges
    future_table_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["SELECT","INSERT","DELETE","UPDATE"],
    }
    future_view_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["SELECT","INSERT","DELETE","UPDATE"],
    }
    future_procedure_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["USAGE"],
    }
    future_function_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["USAGE"],
    }
    future_task_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["OWNERSHIP"],
    }
    future_stage_privileges = {
      "DB_STRAY_KIDS.COMBACKS" = ["READ", "WRITE"],
    }
  },

  # Administrative system role
  "SECURITY_ADMIN_CUSTOM" = {
    comment       = "Custom operational role designed to monitor security metrics"
    granted_roles = []
    granted_users = ["BANGCHAN"]
  },

}
