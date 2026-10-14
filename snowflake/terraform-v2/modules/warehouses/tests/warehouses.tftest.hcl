# Offline tests for the warehouses module (mock provider: no account, no credentials).
#
#   cd modules/warehouses
#   terraform init -backend=false
#   terraform test
#
# Requires Terraform 1.7 or newer. Written without access to a Terraform binary,
# so the first run is also the first check of this file.

mock_provider "snowflake" {}

variables {
  warehouses = {
    WH_SMALL = {}

    WH_BI = {
      warehouse_size    = "LARGE"
      max_cluster_count = 4
      scaling_policy    = "ECONOMY"
      auto_suspend      = 120
    }
  }
}

run "every_definition_becomes_a_resource_with_safe_defaults" {
  command = plan

  assert {
    condition     = sort(keys(snowflake_warehouse.warehouse)) == ["WH_BI", "WH_SMALL"]
    error_message = "Both warehouses should be created."
  }

  assert {
    condition     = snowflake_warehouse.warehouse["WH_SMALL"].auto_suspend == 60
    error_message = "auto_suspend should default to 60 seconds."
  }

  assert {
    condition     = snowflake_warehouse.warehouse["WH_SMALL"].statement_timeout_in_seconds == 3600
    error_message = "Statements should time out after an hour unless told otherwise."
  }

  assert {
    condition     = snowflake_warehouse.warehouse["WH_SMALL"].auto_resume == "true"
    error_message = "auto_resume is a string (\"true\") in provider 2.x."
  }

  assert {
    condition     = snowflake_warehouse.warehouse["WH_BI"].max_cluster_count == 4
    error_message = "The multi-cluster setting should pass through."
  }
}

run "rejects_a_lower_case_name" {
  command         = plan
  variables       { warehouses = { wh_small = {} } }
  expect_failures = [var.warehouses]
}

run "rejects_an_unknown_size" {
  command         = plan
  variables       { warehouses = { WH_X = { warehouse_size = "HUGE" } } }
  expect_failures = [var.warehouses]
}

run "rejects_a_size_above_the_limit" {
  command         = plan
  variables       { warehouses = { WH_X = { warehouse_size = "X4LARGE" } } }
  expect_failures = [var.warehouses]
}

run "accepts_a_larger_size_when_the_limit_is_raised" {
  command         = plan
  variables {
    warehouses         = { WH_X = { warehouse_size = "X4LARGE" } }
    max_warehouse_size = "X4LARGE"
  }
}

run "rejects_an_auto_suspend_below_60_seconds" {
  command         = plan
  variables       { warehouses = { WH_X = { auto_suspend = 10 } } }
  expect_failures = [var.warehouses]
}

run "rejects_auto_suspend_of_zero" {
  command         = plan
  variables       { warehouses = { WH_X = { auto_suspend = 0 } } }
  expect_failures = [var.warehouses]
}

run "rejects_min_clusters_above_max" {
  command         = plan
  variables       { warehouses = { WH_X = { min_cluster_count = 3, max_cluster_count = 2 } } }
  expect_failures = [var.warehouses]
}

run "rejects_more_than_ten_clusters" {
  command         = plan
  variables       { warehouses = { WH_X = { max_cluster_count = 11 } } }
  expect_failures = [var.warehouses]
}

run "rejects_an_unknown_warehouse_type" {
  command         = plan
  variables       { warehouses = { WH_X = { warehouse_type = "GPU" } } }
  expect_failures = [var.warehouses]
}
