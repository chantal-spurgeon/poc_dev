warehouses = {
  "producer_wh" = {
    warehouse_size      = "XSMALL"
    auto_suspend        = 10
    auto_resume         = true
    initially_suspended = true
    comment             = "3RACHA Warehouse"
    warehouse_type      = "STANDARD"
    min_cluster_count   = 1
    max_cluster_count   = 1
  },

  # Multi-cluster scaling compute engine to handle heavy BI tool concurrency
  "reporting_wh" = {
    warehouse_size      = "SMALL"
    auto_suspend        = 120
    auto_resume         = true
    initially_suspended = true
    comment             = "Auto-scaling cluster serving corporate dashboards and spikes"
    warehouse_type      = "STANDARD"
    min_cluster_count   = 1
    max_cluster_count   = 5          # Scales up to 5 clusters during peak heavy traffic hours
    scaling_policy      = "STANDARD" # Instantly spins up new clusters when queries queue up
  },

  # Memory-intensive Snowpark compute for Python Data Science transformations
  "snowpark_wh" = {
    warehouse_size      = "LARGE"
    auto_suspend        = 60
    auto_resume         = true
    initially_suspended = true
    comment             = "Snowpark-optimized engine allocating 16x more RAM per node"
    warehouse_type      = "SNOWPARK-OPTIMIZED" # Switches infrastructure to high-memory instances
    min_cluster_count   = 1
    max_cluster_count   = 2
    scaling_policy      = "ECONOMY"  # Conserves credits by waiting to ensure clusters are full
  },

}

