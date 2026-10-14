# ------------------------------------------------------------------------------
# Naming rules used by the validations below
#   * Every Snowflake object name is written UPPER CASE, exactly as it appears in
#     Snowflake. The code never changes case, so a name here is a name there.
#   * Schemas are written DATABASE.SCHEMA. Database roles are DATABASE.ROLE.
#   * Privileges are UPPER CASE (the provider treats them as case-sensitive).
# ------------------------------------------------------------------------------

variable "external_roles" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Roles that already exist in Snowflake but are NOT managed by this stack.
    They may be named in `inherits`. The five system roles (ACCOUNTADMIN,
    SECURITYADMIN, USERADMIN, SYSADMIN, PUBLIC) are always allowed.
  EOT

  validation {
    condition     = alltrue([for r in var.external_roles : can(regex("^[A-Z][A-Z0-9_$]*$", r))])
    error_message = "external_roles must be UPPER CASE Snowflake identifiers (letters, digits, _ and $, starting with a letter)."
  }
}

variable "protected_roles" {
  type        = list(string)
  default     = ["ACCOUNTADMIN", "SECURITYADMIN", "USERADMIN"]
  description = <<-EOT
    Powerful system roles this stack will not hand out: no role may inherit
    them and they cannot be granted to users here. Grant them by hand in
    Snowflake, so a change to a tfvars file can never widen who holds them.
    (This is how the old code ended up with SYSADMIN holding SECURITYADMIN.)
    SYSADMIN is not protected: custom roles are normally rolled up under it.
  EOT
}

variable "denied_privileges" {
  type        = list(string)
  default     = ["ALL", "ALL PRIVILEGES", "MANAGE GRANTS"]
  description = <<-EOT
    Privileges that cannot be granted through this stack. Each one is either
    a blanket grant or lets the holder grant anything to anyone. Remove an
    entry only as a deliberate, reviewed policy change.
  EOT
}

variable "account_roles" {
  default     = {}
  description = <<-EOT
    Map of role name => role definition. Everything about one role lives in
    one place.

      comment             free text (ignored for system roles)
      inherits            roles whose privileges this role receives
                          (GRANT ROLE <child> TO ROLE <this role>)
      users               users that receive this role
      database_roles      DATABASE.ROLE names granted to this role,
                          e.g. SNOWFLAKE.SECURITY_VIEWER
      account_privileges  account-level privileges, e.g. CREATE DATABASE
      databases           map DATABASE => privileges
      warehouses          map WAREHOUSE => privileges
      integrations        map INTEGRATION => privileges
      schemas             map DATABASE.SCHEMA => {
                            privileges  privileges on the schema itself
                            owner       true = transfer schema OWNERSHIP here
                            objects     map OBJECT TYPE (plural) => {
                                          current  privileges on objects that exist now
                                          future   privileges on objects created later
                                        }
                          }

    A system role (SYSADMIN, ...) may appear as a key so it can inherit custom
    roles or receive grants. It is never created or changed here.
  EOT

  type = map(object({
    comment            = optional(string, "")
    inherits           = optional(list(string), [])
    users              = optional(list(string), [])
    database_roles     = optional(list(string), [])
    account_privileges = optional(list(string), [])
    databases          = optional(map(list(string)), {})
    warehouses         = optional(map(list(string)), {})
    integrations       = optional(map(list(string)), {})
    schemas = optional(map(object({
      privileges = optional(list(string), [])
      owner      = optional(bool, false)
      objects = optional(map(object({
        current = optional(list(string), [])
        future  = optional(list(string), [])
      })), {})
    })), {})
  }))

  validation {
    condition     = alltrue([for name in keys(var.account_roles) : can(regex("^[A-Z][A-Z0-9_$]*$", name))])
    error_message = "Role names must be UPPER CASE Snowflake identifiers (letters, digits, _ and $, starting with a letter)."
  }

  validation {
    condition = alltrue(flatten([
      for role in values(var.account_roles) : [
        for name in concat(role.users, keys(role.databases), keys(role.warehouses), keys(role.integrations)) :
        can(regex("^[A-Z][A-Z0-9_$]*$", name))
      ]
    ]))
    error_message = "User, database, warehouse and integration names must be UPPER CASE Snowflake identifiers (letters, digits, _ and $, starting with a letter)."
  }

  validation {
    condition = alltrue(flatten([
      for role in values(var.account_roles) : concat(
        [for s in keys(role.schemas) : can(regex("^[A-Z][A-Z0-9_$]*[.][A-Z][A-Z0-9_$]*$", s))],
        [for d in role.database_roles : can(regex("^[A-Z][A-Z0-9_$]*[.][A-Z][A-Z0-9_$]*$", d))]
      )
    ]))
    error_message = "Schemas must be written DATABASE.SCHEMA and database roles DATABASE.ROLE, in UPPER CASE."
  }

  validation {
    condition = alltrue(flatten([
      for name, role in var.account_roles : [
        for child in role.inherits :
        child != name && contains(
          concat(keys(var.account_roles), var.external_roles, ["ACCOUNTADMIN", "SECURITYADMIN", "USERADMIN", "SYSADMIN", "PUBLIC"]),
          child
        )
      ]
    ]))
    error_message = "Every entry in `inherits` must be another role defined in account_roles, listed in external_roles, or a system role, and a role cannot inherit itself."
  }

  validation {
    condition = alltrue([
      for p in flatten([
        for role in values(var.account_roles) : concat(
          role.account_privileges,
          flatten(values(role.databases)),
          flatten(values(role.warehouses)),
          flatten(values(role.integrations)),
          flatten([
            for schema in values(role.schemas) : concat(
              schema.privileges,
              flatten([for o in values(schema.objects) : concat(o.current, o.future)])
            )
          ])
        )
      ]) : p == upper(p) && p != "OWNERSHIP"
    ])
    error_message = "Privileges must be UPPER CASE, and OWNERSHIP is not a privilege here: set `owner = true` on the schema to transfer schema ownership."
  }

  validation {
    condition = alltrue(flatten([
      for role in values(var.account_roles) : [
        for schema in values(role.schemas) : [
          for type in keys(schema.objects) : contains([
            "TABLES", "VIEWS", "MATERIALIZED VIEWS", "DYNAMIC TABLES", "EXTERNAL TABLES",
            "EVENT TABLES", "ICEBERG TABLES", "HYBRID TABLES", "STAGES", "FILE FORMATS",
            "SEQUENCES", "STREAMS", "PIPES", "TASKS", "PROCEDURES", "FUNCTIONS", "ALERTS", "SECRETS"
          ], type)
        ]
      ]
    ]))
    error_message = "Object types under `objects` must be one of: TABLES, VIEWS, MATERIALIZED VIEWS, DYNAMIC TABLES, EXTERNAL TABLES, EVENT TABLES, ICEBERG TABLES, HYBRID TABLES, STAGES, FILE FORMATS, SEQUENCES, STREAMS, PIPES, TASKS, PROCEDURES, FUNCTIONS, ALERTS, SECRETS. Extend the list in modules/rbac/variables.tf if you need another."
  }

  validation {
    condition = alltrue(flatten([
      for role in values(var.account_roles) : [
        for schema in values(role.schemas) : [
          for type, o in schema.objects :
          alltrue([for p in concat(o.current, o.future) : contains(["SELECT", "REFERENCES"], p)])
          if type == "VIEWS"
        ]
      ]
    ]))
    error_message = "Views only accept the SELECT and REFERENCES privileges. INSERT, UPDATE and DELETE apply to tables."
  }

  # --- guardrails against privilege escalation --------------------------------
  validation {
    condition = alltrue(flatten([
      for role in values(var.account_roles) : [
        for child in role.inherits : !contains(var.protected_roles, child)
      ]
    ]))
    error_message = "A role cannot inherit a protected role (var.protected_roles: ACCOUNTADMIN, SECURITYADMIN, USERADMIN by default). Whoever holds the inheriting role would get all of that role's power."
  }

  validation {
    condition = alltrue([
      for name, role in var.account_roles : length(role.users) == 0 || !contains(var.protected_roles, name)
    ])
    error_message = "Protected roles (var.protected_roles) cannot be granted to users here. Grant them by hand in Snowflake."
  }

  validation {
    condition = alltrue([
      for p in flatten([
        for role in values(var.account_roles) : concat(
          role.account_privileges,
          flatten(values(role.databases)),
          flatten(values(role.warehouses)),
          flatten(values(role.integrations)),
          flatten([
            for schema in values(role.schemas) : concat(
              schema.privileges,
              flatten([for o in values(schema.objects) : concat(o.current, o.future)])
            )
          ])
        )
      ]) : !contains(var.denied_privileges, p)
    ])
    error_message = "A privilege in var.denied_privileges (ALL, ALL PRIVILEGES, MANAGE GRANTS by default) was requested. List the specific privileges needed, or grant this one by hand."
  }
}
