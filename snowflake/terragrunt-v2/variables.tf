# terragrunt-v2/variables.tf
#
# Connection settings. root.hcl passes these as inputs and builds the provider
# block itself, so nothing else is declared here. The private key and passphrase
# are read by the provider from SNOWFLAKE_PRIVATE_KEY and
# SNOWFLAKE_PRIVATE_KEY_PASSPHRASE.

variable "snowflake_account" {
  type        = string
  description = "Target account (ORG-ACCOUNT) where objects will be built"
}

variable "snowflake_user" {
  type        = string
  description = "The Snowflake user running the Terraform execution"
}

variable "snowflake_role" {
  type        = string
  default     = "ACCOUNTADMIN"
  description = "Role the provider uses. root.hcl picks it per unit from account.hcl."
}

# ==============================================================================
# STRUCTURAL MAPS
# ==============================================================================
# One map per area, each normally filled by one unit only. They are typed objects
# with optional() attributes, so a unit lists only what it needs and the defaults
# below apply. The defaults match what main.tf used to supply through lookup().
#
# Two things to know about typed objects:
#   - A missing REQUIRED attribute (no optional()) is an error, which is the point.
#   - A misspelled attribute name is NOT an error: Terraform silently drops
#     attributes the type does not list. If a setting seems to be ignored, check
#     its spelling against the type here.

variable "databases" {
  type = map(object({
    comment                  = optional(string)
    data_retention_time_days = optional(number, 1)
    is_transient             = optional(bool, false)
    is_replica               = optional(bool, false)
    primary_database_path    = optional(string)
    schemas = optional(map(object({
      comment        = optional(string)
      is_transient   = optional(bool, false)
      managed_access = optional(bool, false)
    })), {})
  }))
  description = "Databases and their schemas. The map key is the Terraform address: do not rename it once created."
  default     = {}
}

variable "warehouses" {
  type = map(object({
    warehouse_size      = optional(string, "XSMALL")
    warehouse_type      = optional(string, "STANDARD")
    auto_suspend        = optional(number, 600)
    auto_resume         = optional(bool, true)
    initially_suspended = optional(bool, true)
    min_cluster_count   = optional(number, 1)
    max_cluster_count   = optional(number, 1)
    scaling_policy      = optional(string, "STANDARD")
    comment             = optional(string)
  }))
  description = "Virtual warehouses."
  default     = {}
}

variable "network_policies" {
  type = map(object({
    allowed_ip_list = list(string)
    blocked_ip_list = optional(list(string))
    comment         = optional(string)
  }))
  description = "Network policies and their allowed/blocked IP ranges."
  default     = {}
}

variable "storage_integrations" {
  type = map(object({
    provider                  = optional(string, "")
    type                      = optional(string)
    comment                   = optional(string)
    storage_allowed_locations = list(string)
    storage_blocked_locations = optional(list(string))
    storage_aws_role_arn      = optional(string)
    azure_tenant_id           = optional(string)
  }))
  description = "AWS (S3), GCS or Azure storage integrations. provider must be S3/AWS, GCS/GOOGLE or AZURE."
  default     = {}
}

variable "account_roles" {
  type = map(object({
    comment                = optional(string)
    granted_roles          = optional(list(string), [])
    granted_users          = optional(list(string), [])
    granted_database_roles = optional(list(string), []) # e.g. "SNOWFLAKE.SECURITY_VIEWER"
    account_privileges     = optional(list(string), [])

    warehouse_privileges   = optional(map(list(string)), {})
    integration_privileges = optional(map(list(string)), {})
    database_privileges    = optional(map(list(string)), {})
    schema_privileges      = optional(map(list(string)), {})

    all_table_privileges     = optional(map(list(string)), {})
    all_view_privileges      = optional(map(list(string)), {})
    all_procedure_privileges = optional(map(list(string)), {})
    all_function_privileges  = optional(map(list(string)), {})
    all_task_privileges      = optional(map(list(string)), {})
    all_stage_privileges     = optional(map(list(string)), {})

    future_table_privileges     = optional(map(list(string)), {})
    future_view_privileges      = optional(map(list(string)), {})
    future_procedure_privileges = optional(map(list(string)), {})
    future_function_privileges  = optional(map(list(string)), {})
    future_task_privileges      = optional(map(list(string)), {})
    future_stage_privileges     = optional(map(list(string)), {})
  }))
  description = "Roles, their memberships and their privileges."
  default     = {}

  # Guard rails. These stop dangerous configuration at plan time.
  validation {
    condition = alltrue(flatten([
      for k, v in var.account_roles : [
        for r in v.granted_roles : !contains(["ACCOUNTADMIN", "SECURITYADMIN", "USERADMIN"], upper(r))
      ]
    ]))
    error_message = "No role may inherit ACCOUNTADMIN, SECURITYADMIN or USERADMIN (granted_roles). Grant them to people by hand if needed."
  }
  validation {
    condition = alltrue([
      for k, v in var.account_roles :
      !(contains(["ACCOUNTADMIN", "SECURITYADMIN", "USERADMIN"], upper(k)) && length(v.granted_users) > 0)
    ])
    error_message = "Do not assign users to ACCOUNTADMIN, SECURITYADMIN or USERADMIN from Terraform."
  }
  validation {
    condition = alltrue(flatten([
      for k, v in var.account_roles : [
        for p in v.account_privileges : !contains(["ALL", "ALL PRIVILEGES", "MANAGE GRANTS"], upper(p))
      ]
    ]))
    error_message = "account_privileges may not contain ALL, ALL PRIVILEGES or MANAGE GRANTS."
  }
}

variable "users" {
  type = map(object({
    user_type               = optional(string, "PERSON") # PERSON or SERVICE
    login_name              = string
    email                   = string
    first_name              = optional(string)
    last_name               = optional(string)
    default_role            = optional(string)
    default_secondary_roles = optional(list(string), [])
    default_warehouse       = optional(string)
    default_namespace       = optional(string)
    default_database        = optional(string)
    default_schema          = optional(string)
    network_policy          = optional(string)
    disabled                = optional(bool, false)
    comment                 = optional(string)
    rsa_public_key          = optional(string)
    rsa_public_key_2        = optional(string)
  }))
  description = "People and service accounts."
  default     = {}
}

# ==============================================================================
# OBJECTS INSIDE SCHEMAS: tables, views, procedures, tasks (see objects.tf)
# ==============================================================================
# The map key is the object's fully qualified name, DATABASE.SCHEMA.NAME, in
# UPPER CASE. The database and schema must already exist (databases unit) and the
# unit's sign-in role needs the matching CREATE privileges (rbac unit).

variable "tables" {
  type = map(object({
    comment                  = optional(string)
    data_retention_time_days = optional(number)
    change_tracking          = optional(bool, false)
    columns = list(object({
      name     = string
      type     = string
      nullable = optional(bool, true)
      comment  = optional(string)
    }))
  }))
  description = "Tables, keyed DATABASE.SCHEMA.TABLE. Never dropped by Terraform (prevent_destroy)."
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.tables) : can(regex("^[A-Z0-9_$]+\\.[A-Z0-9_$]+\\.[A-Z0-9_$]+$", k))])
    error_message = "Table keys must be DATABASE.SCHEMA.TABLE in UPPER CASE."
  }
}

variable "views" {
  type = map(object({
    comment   = optional(string)
    is_secure = optional(bool, false)
    statement = string # the SELECT only, with every table written DATABASE.SCHEMA.TABLE
  }))
  description = "Views, keyed DATABASE.SCHEMA.VIEW."
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.views) : can(regex("^[A-Z0-9_$]+\\.[A-Z0-9_$]+\\.[A-Z0-9_$]+$", k))])
    error_message = "View keys must be DATABASE.SCHEMA.VIEW in UPPER CASE."
  }
}

variable "procedures" {
  type = map(object({
    comment = optional(string)
    arguments = optional(list(object({
      name = string
      type = string
    })), [])
    returns    = string
    execute_as = optional(string, "OWNER") # OWNER or CALLER
    body       = string                    # SQL Scripting: BEGIN ... END; (no $$ markers)
  }))
  description = "SQL stored procedures, keyed DATABASE.SCHEMA.PROCEDURE."
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.procedures) : can(regex("^[A-Z0-9_$]+\\.[A-Z0-9_$]+\\.[A-Z0-9_$]+$", k))])
    error_message = "Procedure keys must be DATABASE.SCHEMA.PROCEDURE in UPPER CASE."
  }
  validation {
    condition     = alltrue([for k, v in var.procedures : contains(["OWNER", "CALLER"], upper(v.execute_as))])
    error_message = "execute_as must be OWNER or CALLER."
  }
}

variable "tasks" {
  type = map(object({
    comment   = optional(string)
    statement = string                    # what the task runs, e.g. CALL DB.SCHEMA.PROC();
    started   = optional(bool, false)     # true = resumed (running on its schedule)
    warehouse = optional(string)          # omit for a serverless task
    serverless_size = optional(string, "XSMALL") # used only when warehouse is omitted
    schedule = optional(object({
      using_cron = optional(string)       # e.g. "0 6 * * * America/Chicago"
      minutes    = optional(number)
      hours      = optional(number)
    }))
  }))
  description = "Standalone scheduled tasks, keyed DATABASE.SCHEMA.TASK."
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.tasks) : can(regex("^[A-Z0-9_$]+\\.[A-Z0-9_$]+\\.[A-Z0-9_$]+$", k))])
    error_message = "Task keys must be DATABASE.SCHEMA.TASK in UPPER CASE."
  }
  validation {
    condition = alltrue([
      for k, v in var.tasks : v.schedule == null ? true : (
        length([for x in [v.schedule.using_cron, v.schedule.minutes, v.schedule.hours] : x if x != null]) == 1
      )
    ])
    error_message = "A task schedule sets exactly one of using_cron, minutes or hours."
  }
}
