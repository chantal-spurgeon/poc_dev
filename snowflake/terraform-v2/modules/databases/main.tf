locals {
  primary_databases = { for name, db in var.databases : name => db if db.replica_of == null }
  replica_databases = { for name, db in var.databases : name => db if db.replica_of != null }

  # key "DATABASE.SCHEMA"
  schemas = {
    for item in flatten([
      for db_name, db in local.primary_databases : [
        for schema_name, s in db.schemas : {
          database       = db_name
          name           = schema_name
          comment        = s.comment
          is_transient   = s.is_transient == null ? db.is_transient : s.is_transient
          managed_access = s.managed_access
          retention_days = s.data_retention_time_days
        }
      ]
    ]) : "${item.database}.${item.name}" => item
  }
}

# ------------------------------------------------------------------------------
# Databases and schemas hold data, so Terraform is not allowed to destroy them:
# removing one from the tfvars, or a change that would force it to be recreated,
# stops with an error instead of dropping data. To retire one on purpose, see
# "Retiring a database or schema" in the README.
# ------------------------------------------------------------------------------
resource "snowflake_database" "database" {
  for_each = local.primary_databases

  name                        = each.key
  comment                     = each.value.comment == "" ? null : each.value.comment
  is_transient                = each.value.is_transient
  data_retention_time_in_days = each.value.data_retention_time_days

  lifecycle {
    prevent_destroy = true
  }
}

# A replica is rebuilt from its primary, so it carries no destroy protection.
resource "snowflake_secondary_database" "replica" {
  for_each = local.replica_databases

  name                        = each.key
  as_replica_of               = join(".", [for part in split(".", each.value.replica_of) : "\"${part}\""])
  comment                     = each.value.comment == "" ? null : each.value.comment
  data_retention_time_in_days = each.value.data_retention_time_days
}

# In provider 2.x a schema's is_transient and with_managed_access are the strings
# "true" / "false" (a database's is_transient is a real boolean).
resource "snowflake_schema" "schema" {
  for_each = local.schemas

  database                    = snowflake_database.database[each.value.database].name
  name                        = each.value.name
  comment                     = each.value.comment == "" ? null : each.value.comment
  is_transient                = tostring(each.value.is_transient)
  with_managed_access         = tostring(each.value.managed_access)
  data_retention_time_in_days = each.value.retention_days

  lifecycle {
    prevent_destroy = true
  }
}
