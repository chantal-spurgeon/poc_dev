# ------------------------------------------------------------------------------
# Names are written UPPER CASE, exactly as they appear in Snowflake. The code
# never changes case, so the rbac stack can refer to a warehouse by the same name.
# ------------------------------------------------------------------------------

variable "max_warehouse_size" {
  type        = string
  default     = "XXLARGE"
  description = <<-EOT
    The largest size any warehouse here may have. A cost guardrail: a typo such
    as X6LARGE in a tfvars file is rejected at plan time instead of billed.
    Raise it deliberately, in a reviewed change, when a workload needs more.
  EOT
}

variable "warehouses" {
  default     = {}
  description = <<-EOT
    Map of warehouse name => definition.

      warehouse_size                XSMALL SMALL MEDIUM LARGE XLARGE XXLARGE XXXLARGE
                                    X4LARGE X5LARGE X6LARGE (at most var.max_warehouse_size)
      warehouse_type                STANDARD or SNOWPARK-OPTIMIZED
      auto_suspend                  seconds idle before suspending, 60 to 86400.
                                    Snowflake bills at least 60 seconds each time a
                                    warehouse resumes, so a lower value saves nothing
                                    and empties the cache. There is no "never suspend".
      auto_resume                   start automatically when a query arrives
      initially_suspended           create it suspended (no cost until first use)
      min_cluster_count / max_cluster_count
                                    1 to 10. More than 1 is a multi-cluster warehouse
                                    (Enterprise edition or higher)
      scaling_policy                STANDARD or ECONOMY (multi-cluster only)
      statement_timeout_in_seconds  cancel any statement running longer than this.
                                    Snowflake's own default is 172800 (2 days); this
                                    stack defaults to 3600 so a runaway query cannot
                                    run up two days of credits.
      comment                       free text
  EOT

  type = map(object({
    warehouse_size               = optional(string, "XSMALL")
    warehouse_type               = optional(string, "STANDARD")
    auto_suspend                 = optional(number, 60)
    auto_resume                  = optional(bool, true)
    initially_suspended          = optional(bool, true)
    min_cluster_count            = optional(number, 1)
    max_cluster_count            = optional(number, 1)
    scaling_policy               = optional(string, "STANDARD")
    statement_timeout_in_seconds = optional(number, 3600)
    comment                      = optional(string, "")
  }))

  validation {
    condition     = alltrue([for name in keys(var.warehouses) : can(regex("^[A-Z][A-Z0-9_$]*$", name))])
    error_message = "Warehouse names must be UPPER CASE Snowflake identifiers (letters, digits, _ and $, starting with a letter)."
  }

  validation {
    condition = alltrue([
      for w in values(var.warehouses) :
      contains(["XSMALL", "SMALL", "MEDIUM", "LARGE", "XLARGE", "XXLARGE", "XXXLARGE", "X4LARGE", "X5LARGE", "X6LARGE"], w.warehouse_size)
    ])
    error_message = "warehouse_size must be one of XSMALL, SMALL, MEDIUM, LARGE, XLARGE, XXLARGE, XXXLARGE, X4LARGE, X5LARGE, X6LARGE."
  }

  validation {
    condition = alltrue([
      for w in values(var.warehouses) : try(
        index(["XSMALL", "SMALL", "MEDIUM", "LARGE", "XLARGE", "XXLARGE", "XXXLARGE", "X4LARGE", "X5LARGE", "X6LARGE"], w.warehouse_size) <=
        index(["XSMALL", "SMALL", "MEDIUM", "LARGE", "XLARGE", "XXLARGE", "XXXLARGE", "X4LARGE", "X5LARGE", "X6LARGE"], var.max_warehouse_size),
        false
      )
    ])
    error_message = "A warehouse is larger than var.max_warehouse_size (default XXLARGE). Pick a smaller size, or raise the limit as a reviewed policy change."
  }

  validation {
    condition     = alltrue([for w in values(var.warehouses) : contains(["STANDARD", "SNOWPARK-OPTIMIZED"], w.warehouse_type)])
    error_message = "warehouse_type must be STANDARD or SNOWPARK-OPTIMIZED."
  }

  validation {
    condition     = alltrue([for w in values(var.warehouses) : w.auto_suspend >= 60 && w.auto_suspend <= 86400])
    error_message = "auto_suspend must be between 60 and 86400 seconds. Below 60 saves nothing (Snowflake bills 60 seconds on every resume) and 0 or none would keep the warehouse running and billing."
  }

  validation {
    condition = alltrue([
      for w in values(var.warehouses) :
      w.min_cluster_count >= 1 && w.max_cluster_count <= 10 && w.min_cluster_count <= w.max_cluster_count
    ])
    error_message = "Cluster counts must satisfy 1 <= min_cluster_count <= max_cluster_count <= 10."
  }

  validation {
    condition     = alltrue([for w in values(var.warehouses) : contains(["STANDARD", "ECONOMY"], w.scaling_policy)])
    error_message = "scaling_policy must be STANDARD or ECONOMY."
  }

  validation {
    condition     = alltrue([for w in values(var.warehouses) : w.statement_timeout_in_seconds >= 1 && w.statement_timeout_in_seconds <= 604800])
    error_message = "statement_timeout_in_seconds must be between 1 and 604800 (7 days)."
  }
}
