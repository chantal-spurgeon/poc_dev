locals {
  system_roles = ["ACCOUNTADMIN", "SECURITYADMIN", "USERADMIN", "SYSADMIN", "PUBLIC"]

  # Roles this stack creates. System roles may be keys in account_roles (so they
  # can inherit custom roles) but are never created here.
  managed_roles = {
    for name, role in var.account_roles : name => role
    if !contains(local.system_roles, name)
  }

  # name => name for every role that can appear in a grant. Managed roles come
  # from the resource, which makes each grant wait until its role exists.
  role_names = merge(
    { for name in concat(local.system_roles, var.external_roles) : name => name },
    { for name, role in snowflake_account_role.role : name => role.name }
  )

  # --- role hierarchy: key "PARENT<-CHILD" means PARENT inherits CHILD ---------
  role_inheritance = {
    for pair in flatten([
      for parent, role in var.account_roles : [
        for child in role.inherits : { parent = parent, child = child }
      ]
    ]) : "${pair.parent}<-${pair.child}" => pair
  }

  # --- users and database roles: key "ROLE:USER" / "ROLE:DB.ROLE" ----------------
  user_grants = {
    for pair in flatten([
      for name, role in var.account_roles : [
        for user in role.users : { role = name, user = user }
      ]
    ]) : "${pair.role}:${pair.user}" => pair
  }

  database_role_grants = {
    for pair in flatten([
      for name, role in var.account_roles : [
        for dbrole in role.database_roles : {
          role = name
          name = dbrole
          fqn  = join(".", [for part in split(".", dbrole) : "\"${part}\""])
        }
      ]
    ]) : "${pair.role}:${pair.name}" => pair
  }

  # --- account-level privileges: key "ROLE" ------------------------------------
  account_grants = {
    for name, role in var.account_roles : name => role.account_privileges
    if length(role.account_privileges) > 0
  }

  # --- databases, warehouses, integrations: key "ROLE:TYPE:NAME" ----------------
  account_object_grants = {
    for grant in flatten([
      for name, role in var.account_roles : concat(
        [for n, p in role.databases : { role = name, type = "DATABASE", name = n, privileges = p }],
        [for n, p in role.warehouses : { role = name, type = "WAREHOUSE", name = n, privileges = p }],
        [for n, p in role.integrations : { role = name, type = "INTEGRATION", name = n, privileges = p }]
      )
    ]) : "${grant.role}:${grant.type}:${grant.name}" => grant
    if length(grant.privileges) > 0
  }

  # --- schemas and the objects inside them -------------------------------------
  schema_entries = flatten([
    for name, role in var.account_roles : [
      for schema, config in role.schemas : {
        role       = name
        schema     = schema
        fqn        = join(".", [for part in split(".", schema) : "\"${part}\""])
        privileges = config.privileges
        owner      = config.owner
        objects    = config.objects
      }
    ]
  ])

  # key "ROLE:DB.SCHEMA"
  schema_grants    = { for e in local.schema_entries : "${e.role}:${e.schema}" => e if length(e.privileges) > 0 }
  schema_ownership = { for e in local.schema_entries : "${e.role}:${e.schema}" => e if e.owner }

  object_entries = flatten([
    for e in local.schema_entries : [
      for type, o in e.objects : {
        role    = e.role
        schema  = e.schema
        fqn     = e.fqn
        type    = type
        current = o.current
        future  = o.future
      }
    ]
  ])

  # key "ROLE:DB.SCHEMA:TYPE"
  object_grants_current = { for e in local.object_entries : "${e.role}:${e.schema}:${e.type}" => e if length(e.current) > 0 }
  object_grants_future  = { for e in local.object_entries : "${e.role}:${e.schema}:${e.type}" => e if length(e.future) > 0 }
}

# ------------------------------------------------------------------------------
# Roles and hierarchy
# ------------------------------------------------------------------------------
resource "snowflake_account_role" "role" {
  for_each = local.managed_roles

  name    = each.key
  comment = each.value.comment == "" ? null : each.value.comment
}

resource "snowflake_grant_account_role" "inheritance" {
  for_each = local.role_inheritance

  role_name        = local.role_names[each.value.child]
  parent_role_name = local.role_names[each.value.parent]
}

resource "snowflake_grant_account_role" "to_user" {
  for_each = local.user_grants

  role_name = local.role_names[each.value.role]
  user_name = each.value.user
}

resource "snowflake_grant_database_role" "to_role" {
  for_each = local.database_role_grants

  database_role_name = each.value.fqn
  parent_role_name   = local.role_names[each.value.role]
}

# ------------------------------------------------------------------------------
# Privileges
# ------------------------------------------------------------------------------
resource "snowflake_grant_privileges_to_account_role" "account" {
  for_each = local.account_grants

  account_role_name = local.role_names[each.key]
  on_account        = true
  privileges        = each.value
}

resource "snowflake_grant_privileges_to_account_role" "account_object" {
  for_each = local.account_object_grants

  account_role_name = local.role_names[each.value.role]
  privileges        = each.value.privileges

  on_account_object {
    object_type = each.value.type
    object_name = each.value.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "schema" {
  for_each = local.schema_grants

  account_role_name = local.role_names[each.value.role]
  privileges        = each.value.privileges

  on_schema {
    schema_name = each.value.fqn
  }
}

# Objects that exist when this runs. Objects created later are not covered:
# that is what the `future` grants below are for.
resource "snowflake_grant_privileges_to_account_role" "schema_objects_current" {
  for_each = local.object_grants_current

  account_role_name = local.role_names[each.value.role]
  privileges        = each.value.current

  on_schema_object {
    all {
      object_type_plural = each.value.type
      in_schema          = each.value.fqn
    }
  }
}

resource "snowflake_grant_privileges_to_account_role" "schema_objects_future" {
  for_each = local.object_grants_future

  account_role_name = local.role_names[each.value.role]
  privileges        = each.value.future

  on_schema_object {
    future {
      object_type_plural = each.value.type
      in_schema          = each.value.fqn
    }
  }
}

# ------------------------------------------------------------------------------
# Ownership. COPY keeps the grants other roles already hold on the schema.
# Note: schema-level future grants take precedence over database-level ones.
# ------------------------------------------------------------------------------
resource "snowflake_grant_ownership" "schema" {
  for_each = local.schema_ownership

  account_role_name   = local.role_names[each.value.role]
  outbound_privileges = "COPY"

  on {
    object_type = "SCHEMA"
    object_name = each.value.fqn
  }
}
