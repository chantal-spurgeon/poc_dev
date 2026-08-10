# environment/snowflake_account_name/warehouses/terragrunt.hcl

# Inherit the global backend, account settings, and Snowflake providers
include "root" {
  path   = find_in_parent_folders("root.hcl")
}

# Point to your monolithic terraform source directory
terraform {
  source = "${get_repo_root()}//snowflake/terragrunt"
}

# Inject your warehouses configuration directly into the inputs block
inputs = {
  warehouses = {
    "producer8_wh" = {
      warehouse_size      = "XSMALL"
      auto_suspend        = 10
      auto_resume         = true
      initially_suspended = true
      comment             = "3RACHA Warehouse"
      warehouse_type      = "STANDARD"
      min_cluster_count   = 1
      max_cluster_count   = 1
    }

    "reporting8_wh" = {
      warehouse_size      = "SMALL"
      auto_suspend        = 120
      auto_resume         = true
      initially_suspended = true
      comment             = "Auto-scaling cluster serving corporate dashboards and spikes"
      warehouse_type      = "STANDARD"
      min_cluster_count   = 1
      max_cluster_count   = 5
      scaling_policy      = "STANDARD"
    }

    "snowpark8_wh" = {
      warehouse_size      = "LARGE"
      auto_suspend        = 60
      auto_resume         = true
      initially_suspended = true
      comment             = "Snowpark-optimized engine allocating 16x more RAM per node"
      warehouse_type      = "SNOWPARK-OPTIMIZED"
      min_cluster_count   = 1
      max_cluster_count   = 2
      scaling_policy      = "ECONOMY"
    }
  }
}
