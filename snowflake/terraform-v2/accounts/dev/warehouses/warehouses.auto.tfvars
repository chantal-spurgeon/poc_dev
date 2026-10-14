# Warehouses. This is the only file you edit to change them.
# Running Terraform in this folder cannot touch roles, grants, databases or users.
#
# Conventions: UPPER CASE names, written exactly as Snowflake has them. Privileges on a
# warehouse are granted in the rbac stack, by the same name.
#
# Cost guardrails (see modules/warehouses/variables.tf): auto_suspend is at least 60
# seconds, statements time out after an hour unless told otherwise, and no warehouse
# may be larger than XXLARGE.

warehouses = {

  PRODUCER_WH = {
    comment        = "3RACHA Warehouse"
    warehouse_size = "XSMALL"
    # The old file used 10 seconds. Snowflake bills at least 60 seconds each time a
    # warehouse resumes, so anything lower saves nothing and empties the cache.
    auto_suspend = 60
  }

  # Multi-cluster: scales out to handle many BI users at once. Needs Enterprise edition.
  REPORTING_WH = {
    comment           = "Auto-scaling cluster serving corporate dashboards and spikes"
    warehouse_size    = "SMALL"
    auto_suspend      = 120
    max_cluster_count = 5
    scaling_policy    = "STANDARD" # start another cluster as soon as queries queue
  }

  # Memory-heavy compute for Python / Snowpark work.
  SNOWPARK_WH = {
    comment           = "Snowpark-optimized engine allocating 16x more RAM per node"
    warehouse_size    = "LARGE"
    warehouse_type    = "SNOWPARK-OPTIMIZED"
    auto_suspend      = 60
    max_cluster_count = 2
    scaling_policy    = "ECONOMY" # wait until a cluster would be full before adding one
  }
}
