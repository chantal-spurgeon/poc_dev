variable "snowflake_organization" {
  type        = string
  description = "The Snowflake organization name"
}

variable "snowflake_account" {
  type        = string
  description = "Target account name where objects will be built"
}

# The Map structure for the Databases input file
variable "databases" {
  type = map(object({
    comment                  = string
    data_retention_time_days = number
    is_transient             = bool

    # Replication configuration parameters (Optional)
    is_replica             = optional(bool, false)
    primary_database_path  = optional(string, null) # Pattern: "ORG_NAME.PRIMARY_ACCOUNT_NAME.DB_NAME"

    schemas = optional(map(object({
      comment           = string
      is_transient      = bool
      managed_access    = bool
    })), {})
  }))
  default     = {}
  description = "Map of individual database configurations, schemas, and replication settings."
}

# The Map structure for the Warehouses input file
variable "warehouses" {
  type = map(object({
    warehouse_size      = string # XSMALL, SMALL, MEDIUM, LARGE, etc.
    auto_suspend        = number # In seconds
    auto_resume         = bool
    initially_suspended = bool
    comment             = string
    warehouse_type      = optional(string, "STANDARD") # STANDARD, SNOWPARK-OPTIMIZED
    min_cluster_count   = optional(number, 1)          # Minimum running clusters for scaling
    max_cluster_count   = optional(number, 1)          # Max cluster ceiling for concurrency scaling
    scaling_policy      = optional(string, "STANDARD") # STANDARD, ECONOMY
  }))
  default     = {}
  description = "Map of virtual warehouse configurations"
}

# Network Policies Map
variable "network_policies" {
  type = map(object({
    allowed_ip_list = list(string)
    blocked_ip_list = optional(list(string), [])
    comment         = string
  }))
  default = {}
}

# Storage Integrations Map
variable "storage_integrations" {
  type = map(object({
    type            = string           # EXTERNAL_STAGE
    provider        = string           # S3, S3_COMPATIBLE, AZURE, GCS
    storage_allowed_locations = list(string)
    storage_blocked_locations = optional(list(string), [])
    storage_aws_role_arn      = optional(string, null) # Required for AWS S3
    comment         = string
  }))
  default = {}
}

# Custom Security Roles Map
variable "account_roles" {
  type = map(object({
    comment                = string
    granted_roles          = optional(list(string), [])
    granted_users          = optional(list(string), [])
    account_privileges     = optional(list(string), [])
    database_privileges    = optional(map(list(string)), {})
    warehouse_privileges   = optional(map(list(string)), {})
    integration_privileges = optional(map(list(string)), {})
    schema_privileges      = optional(map(list(string)), {}) # e.g., "ANALYTICS_DB.CORE_MART" = ["USAGE", "CREATE TABLE"]
    # Existing Objects (ALL)
    all_table_privileges    = optional(map(list(string)), {}) # e.g., "ANALYTICS_DB.CORE_MART" = ["SELECT"]
    all_view_privileges     = optional(map(list(string)), {})  # e.g., "ANALYTICS_DB.CORE_MART" = ["SELECT"]
    all_procedure_privileges = optional(map(list(string)), {}) # e.g. ["USAGE"]
    all_function_privileges  = optional(map(list(string)), {}) # e.g. ["USAGE"]
    all_task_privileges      = optional(map(list(string)), {}) # e.g. ["OPERATE", "MONITOR"]
    all_stage_privileges     = optional(map(list(string)), {}) # e.g. ["READ", "WRITE"]
    # Future Objects (FUTURE)
    future_table_privileges = optional(map(list(string)), {}) # e.g., "ANALYTICS_DB.CORE_MART" = ["SELECT"]
    future_view_privileges  = optional(map(list(string)), {})  # e.g., "ANALYTICS_DB.CORE_MART" = ["SELECT"]
    future_procedure_privileges = optional(map(list(string)), {})
    future_function_privileges  = optional(map(list(string)), {})
    future_task_privileges      = optional(map(list(string)), {})
    future_stage_privileges     = optional(map(list(string)), {})
  }))
  default     = {}
  description = "A centralized map of account roles, hierarchies, user assignments, and resource privileges."
}

# Users Map
variable "users" {
  type = map(object({
    login_name         = string
    email              = string
    first_name         = optional(string, null) # Optional for Service users
    last_name          = optional(string, null) # Optional for Service users
    default_role       = string
    default_warehouse  = string
    default_database   = optional(string, null) # e.g., "ANALYTICS_DB"
    default_schema     = optional(string, null) # e.g., "CORE_MART"
    disabled           = optional(bool, false)
    comment            = string
    user_type          = optional(string, "PERSON") # PERSON, SERVICE, LEGACY_SERVICE
    rsa_public_key     = optional(string, null)     # String containing the public key body
    rsa_public_key_2   = optional(string, null)     # Optional secondary key for key rotation
  }))
  default     = {}
  description = "A centralized map of human operators and automated service accounts."
}


