# ------------------------------------------------------------------------------
# Naming rules used by the validations below
#   * Every name is written UPPER CASE, exactly as it appears in Snowflake. The
#     code never changes case, so a name here is a name there, and the rbac
#     stack can refer to it by the same spelling.
# ------------------------------------------------------------------------------

variable "reserved_databases" {
  type        = list(string)
  default     = ["SNOWFLAKE", "SNOWFLAKE_SAMPLE_DATA", "SNOWFLAKE_LEARNING_DB"]
  description = <<-EOT
    Databases that belong to Snowflake. They cannot be defined here, so a typo
    or a copy-paste can never try to create, change or drop one of them.
  EOT
}

variable "databases" {
  default     = {}
  description = <<-EOT
    Map of database name => definition.

      comment                   free text
      is_transient              true = no Fail-safe, Time Travel limited to 1 day.
                                Cheaper, and not recoverable after Time Travel ends.
      data_retention_time_days  Time Travel window, 0 to 90 (0 to 1 if transient;
                                values above 1 need Enterprise edition or higher)
      replica_of                ORG.ACCOUNT.DATABASE of a primary database: this
                                one is then created as a read-only replica of it.
                                Replicas cannot define schemas.
      schemas                   map SCHEMA => {
                                  comment
                                  is_transient              default: same as the database
                                  managed_access            true = only the schema owner
                                                            (or MANAGE GRANTS) can grant
                                                            privileges on its objects
                                  data_retention_time_days  default: inherit the database
                                }

    Databases and schemas are never dropped by this stack: Terraform refuses
    (prevent_destroy). See the README for how to retire one on purpose.
  EOT

  type = map(object({
    comment                  = optional(string, "")
    is_transient             = optional(bool, false)
    data_retention_time_days = optional(number, 1)
    replica_of               = optional(string)
    schemas = optional(map(object({
      comment                  = optional(string, "")
      is_transient             = optional(bool)
      managed_access           = optional(bool, false)
      data_retention_time_days = optional(number)
    })), {})
  }))

  validation {
    condition     = alltrue([for name in keys(var.databases) : can(regex("^[A-Z][A-Z0-9_$]*$", name))])
    error_message = "Database names must be UPPER CASE Snowflake identifiers (letters, digits, _ and $, starting with a letter)."
  }

  validation {
    condition = alltrue(flatten([
      for db in values(var.databases) : [
        for name in keys(db.schemas) : can(regex("^[A-Z][A-Z0-9_$]*$", name)) && name != "INFORMATION_SCHEMA"
      ]
    ]))
    error_message = "Schema names must be UPPER CASE Snowflake identifiers (letters, digits, _ and $, starting with a letter). INFORMATION_SCHEMA is created by Snowflake and cannot be defined."
  }

  validation {
    condition     = alltrue([for name in keys(var.databases) : !contains(var.reserved_databases, name)])
    error_message = "A database name in the input is reserved for Snowflake (var.reserved_databases: SNOWFLAKE, SNOWFLAKE_SAMPLE_DATA, SNOWFLAKE_LEARNING_DB)."
  }

  validation {
    condition = alltrue([
      for db in values(var.databases) :
      db.data_retention_time_days >= 0 && db.data_retention_time_days <= (db.is_transient ? 1 : 90)
    ])
    error_message = "data_retention_time_days must be between 0 and 90, and at most 1 for a transient database."
  }

  validation {
    condition = alltrue(flatten([
      for db in values(var.databases) : [
        for s in values(db.schemas) :
        s.data_retention_time_days == null ? true : (
          s.data_retention_time_days >= 0 &&
          s.data_retention_time_days <= ((s.is_transient == null ? db.is_transient : s.is_transient) ? 1 : 90)
        )
      ]
    ]))
    error_message = "A schema's data_retention_time_days must be between 0 and 90, and at most 1 if the schema is transient (which it is by default when its database is)."
  }

  validation {
    condition = alltrue([
      for db in values(var.databases) :
      !db.is_transient ? true : alltrue([for s in values(db.schemas) : s.is_transient == null ? true : s.is_transient])
    ])
    error_message = "A transient database can only contain transient schemas. Remove is_transient = false from the schema, or make the database permanent."
  }

  validation {
    condition = alltrue([
      for db in values(var.databases) :
      db.replica_of == null ? true : can(regex("^[A-Z][A-Z0-9_$]*[.][A-Z][A-Z0-9_$]*[.][A-Z][A-Z0-9_$]*$", db.replica_of))
    ])
    error_message = "replica_of must be written ORGANIZATION.ACCOUNT.DATABASE in UPPER CASE."
  }

  validation {
    condition = alltrue([
      for db in values(var.databases) :
      db.replica_of == null ? true : length(db.schemas) == 0
    ])
    error_message = "A replica copies its schemas from the primary database, so it cannot define schemas here."
  }
}
