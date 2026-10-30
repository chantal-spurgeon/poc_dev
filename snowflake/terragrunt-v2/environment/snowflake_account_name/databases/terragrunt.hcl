# environment/snowflake_account_name/databases/terragrunt.hcl

include "root" {
  path   = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}//snowflake/terragrunt-v2"
}

inputs = {
  databases = {
    "db_stray_kids8" = {
      comment                  = "Production chaos."
      data_retention_time_days = 1
      is_transient            = true

      schemas = {
        "chans_laptop" = {
          comment        = "The area we all want to see but never will"
          is_transient   = true
          managed_access = false
        },
        "comebacks" = {
          comment        = "The final product we love"
          is_transient   = true
          managed_access = true
        }
      }
    },

    # Home of the standard monitoring objects (the monitoring unit fills it).
    "admin_db" = {
      comment = "Admin and FinOps objects"
      schemas = {
        "finops" = {
          comment = "Monitoring tables, views, procedures and tasks"
        }
      }
    }

#    "db_stray_kids_replica" = {
#      comment                  = "Disaster Recovery Archive."
#      data_retention_time_days = 1
#      is_transient            = true
#      is_replica              = true
#      primary_database_path    = "MY_ORG_NAME.PRIMARY_PROD_ACCOUNT.DATABASE"
#      schemas                  = {}
#    },
  }

}
