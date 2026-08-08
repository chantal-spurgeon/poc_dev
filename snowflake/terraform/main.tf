######## databases.tfvars ########
# Provision standard primary Databases (where is_replica is false)
resource "snowflake_database" "managed_dbs" {
  for_each = { for k, v in var.databases : k => v if !lookup(v, "is_replica", false) }

  name                        = upper(each.key)
  comment                     = each.value.comment
  data_retention_time_in_days = each.value.data_retention_time_days
  is_transient                = each.value.is_transient
}

# Provision secondary replicated Databases (where is_replica is true)
resource "snowflake_secondary_database" "managed_replicas" {
  for_each = { for k, v in var.databases : k => v if lookup(v, "is_replica", false) }

  name           = upper(each.key)
  comment        = each.value.comment

  # Natively references the remote qualified parent path using the modern schema variable
  as_replica_of  = each.value.primary_database_path
}

# Flatten and provision nested Schemas (Only loops through databases with schemas defined)
resource "snowflake_schema" "managed_schemas" {
  for_each = merge([
    for db_key, db_val in var.databases : {
      for schema_key, schema_val in db_val.schemas :
      "${db_key}.${schema_key}" => {
        database       = db_key
        schema         = schema_key
        comment        = schema_val.comment
        is_transient   = schema_val.is_transient
        managed_access = schema_val.managed_access
      }
    }
  ]...)

  database           = snowflake_database.managed_dbs[each.value.database].name
  name               = upper(each.value.schema)
  comment            = each.value.comment
  is_transient       = each.value.is_transient
  with_managed_access = each.value.managed_access
}

######## warehouses.tfvars ########
# Provision Warehouses dynamically from variables file mapping
resource "snowflake_warehouse" "managed_whs" {
  for_each = var.warehouses

  name                = upper(each.key)
  warehouse_size      = each.value.warehouse_size
  auto_suspend        = each.value.auto_suspend
  auto_resume         = each.value.auto_resume
  initially_suspended = each.value.initially_suspended
  comment             = each.value.comment
  warehouse_type    = each.value.warehouse_type
  min_cluster_count = each.value.min_cluster_count
  max_cluster_count = each.value.max_cluster_count
  scaling_policy    = each.value.scaling_policy
}

######## security.tfvars ########
# Provision Network Protection Policies
resource "snowflake_network_policy" "security_policies" {
  for_each = var.network_policies

  name            = upper(each.key)
  allowed_ip_list = each.value.allowed_ip_list
  blocked_ip_list = each.value.blocked_ip_list
  comment         = each.value.comment
}

######## integrations.tfvars ########
# Provision Secure Storage Connectors
resource "snowflake_storage_integration" "cloud_links" {
  for_each = var.storage_integrations

  name                      = upper(each.key)
  type                      = each.value.type
  storage_provider          = each.value.provider
  storage_allowed_locations = each.value.storage_allowed_locations
  storage_blocked_locations = each.value.storage_blocked_locations

  # AWS Role attachment pattern
  storage_aws_role_arn      = each.value.storage_aws_role_arn
  enabled                   = true
  comment                   = each.value.comment
}

######## rbac.tfvars ########
# Provision the core roles
resource "snowflake_account_role" "rbac_roles" {
  for_each = var.account_roles
  name    = upper(each.key)
  comment = each.value.comment
}

# Flatten and map the Role-to-Role hierarchies
resource "snowflake_grant_account_role" "role_to_role_grants" {
  for_each = merge([
    for parent_role, configurations in var.account_roles : {
      for child_role in configurations.granted_roles :
      "${parent_role}_INHERITS_${child_role}" => {
        parent_name = upper(parent_role)
        child_name  = upper(child_role)
      }
    }
  ]...)

  # The role receiving the permissions
  parent_role_name = snowflake_account_role.rbac_roles[each.value.parent_name].name

  # The role whose permissions are being inherited
  # Uses a dynamic string lookup in case the child is a native Snowflake system role (like SYSADMIN)
  role_name        = try(snowflake_account_role.rbac_roles[each.value.child_name].name, each.value.child_name)
}

# Flatten and map the User-to-Role assignments
# User-to-Role assignments matrix
resource "snowflake_grant_account_role" "user_to_role_grants" {
  for_each = merge([
    for role_name, configurations in var.account_roles : {
      for user_name in configurations.granted_users :
      "${user_name}_ASSIGNED_TO_${role_name}" => {
        role_target = upper(role_name)
        user_target = upper(user_name)
      }
    }
  ]...)

  role_name = snowflake_account_role.rbac_roles[each.value.role_target].name
  user_name = each.value.user_target

  depends_on = [
    snowflake_user.corporate_users
  ]
}


# Account-Level Privileges
resource "snowflake_grant_privileges_to_account_role" "account_grants" {
  for_each = merge([
    for role_key, role_val in var.account_roles : {
      for privilege in role_val.account_privileges :
      "${role_key}_ACCOUNT_${privilege}" => {
        role      = upper(role_key)
        privilege = privilege
      }
    }
  ]...)

  account_role_name = snowflake_account_role.rbac_roles[each.value.role].name
  on_account        = true
  privileges        = [each.value.privilege]
}

# Database-Level Privileges
resource "snowflake_grant_privileges_to_account_role" "database_grants" {
  for_each = merge([
    for role_key, role_val in var.account_roles : {
      for db_key, privileges in role_val.database_privileges :
      "${role_key}_DB_${db_key}" => {
        role       = upper(role_key)
        db_name    = upper(db_key)
        privileges = privileges
      }
    }
  ]...)

  account_role_name = snowflake_account_role.rbac_roles[each.value.role].name
  on_account_object {
    object_type = "DATABASE"
    object_name = each.value.db_name
  }
  privileges = each.value.privileges

  # Ensure the target database exists if managed by this same repository
  depends_on = [snowflake_database.managed_dbs]
}

# Schema-Level Privileges
resource "snowflake_grant_privileges_to_account_role" "schema_grants" {
  for_each = merge([
    for role_key, role_val in var.account_roles : {
      for target_path, privileges in role_val.schema_privileges :
      "${role_key}_SCHEMA_${target_path}" => {
        role        = upper(role_key)
        db_name     = upper(split(".", target_path)[0])
        schema_name = upper(split(".", target_path)[1])
        privileges  = privileges
      }
    }
  ]...)

  account_role_name = snowflake_account_role.rbac_roles[each.value.role].name

  on_schema {
    schema_name = "\"${each.value.db_name}\".\"${each.value.schema_name}\""
  }

  privileges = each.value.privileges
  depends_on = [snowflake_schema.managed_schemas]
}

# Bulk Existing Object Privileges (ALL Tables, Views, Stages, Tasks, etc.)
resource "snowflake_grant_privileges_to_account_role" "bulk_all_grants" {
  for_each = merge([
    for role_key, role_val in var.account_roles : [
      for type, mappings in {
        "TABLES"     = role_val.all_table_privileges
        "VIEWS"      = role_val.all_view_privileges
        "PROCEDURES" = role_val.all_procedure_privileges
        "FUNCTIONS"  = role_val.all_function_privileges
        "TASKS"      = role_val.all_task_privileges
        "STAGES"     = role_val.all_stage_privileges
      } : {
        for target_path, privileges in mappings :
        "${role_key}_ALL_${type}_${target_path}" => {
          role        = upper(role_key)
          plural_type = type # Plural form restored (e.g., TABLES, VIEWS)
          db_name     = upper(split(".", target_path)[0])
          schema_name = upper(split(".", target_path)[1])
          privileges  = privileges
        }
      }
    ]
  ]...)

  account_role_name = snowflake_account_role.rbac_roles[each.value.role].name

  # FIX: Object parameters are nested completely inside the 'all' schema block
  on_schema_object {
    all {
      object_type_plural = each.value.plural_type
      in_schema          = "\"${each.value.db_name}\".\"${each.value.schema_name}\""
    }
  }

  privileges = each.value.privileges
  depends_on = [snowflake_schema.managed_schemas]
}

# Bulk Future Object Privileges (FUTURE Tables, Views, Stages, Tasks, etc.)
resource "snowflake_grant_privileges_to_account_role" "bulk_future_grants" {
  for_each = merge([
    for role_key, role_val in var.account_roles : [
      for type, mappings in {
        "TABLES"     = role_val.future_table_privileges
        "VIEWS"      = role_val.future_view_privileges
        "PROCEDURES" = role_val.future_procedure_privileges
        "FUNCTIONS"  = role_val.future_function_privileges
        "TASKS"      = role_val.future_task_privileges
        "STAGES"     = role_val.future_stage_privileges
      } : {
        for target_path, privileges in mappings :
        "${role_key}_FUTURE_${type}_${target_path}" => {
          role        = upper(role_key)
          plural_type = type # Plural form restored (e.g., TABLES, VIEWS)
          db_name     = upper(split(".", target_path)[0])
          schema_name = upper(split(".", target_path)[1])
          privileges  = privileges
        }
      }
    ]
  ]...)

  account_role_name = snowflake_account_role.rbac_roles[each.value.role].name

  # FIX: Object parameters are nested completely inside the 'future' schema block
  on_schema_object {
    future {
      object_type_plural = each.value.plural_type
      in_schema          = "\"${each.value.db_name}\".\"${each.value.schema_name}\""
    }
  }

  privileges = each.value.privileges
  depends_on = [snowflake_schema.managed_schemas]
}

# Warehouse-Level Privileges
resource "snowflake_grant_privileges_to_account_role" "warehouse_grants" {
  for_each = merge([
    for role_key, role_val in var.account_roles : {
      for wh_key, privileges in role_val.warehouse_privileges :
      "${role_key}_WH_${wh_key}" => {
        role       = upper(role_key)
        wh_name    = upper(wh_key)
        privileges = privileges
      }
    }
  ]...)

  account_role_name = snowflake_account_role.rbac_roles[each.value.role].name
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = each.value.wh_name
  }
  privileges = each.value.privileges

  depends_on = [snowflake_warehouse.managed_whs]
}

# Storage Integration-Level Privileges
resource "snowflake_grant_privileges_to_account_role" "integration_grants" {
  for_each = merge([
    for role_key, role_val in var.account_roles : {
      for integration_key, privileges in role_val.integration_privileges :
      "${role_key}_INT_${integration_key}" => {
        role             = upper(role_key)
        integration_name = upper(integration_key)
        privileges       = privileges
      }
    }
  ]...)

  account_role_name = snowflake_account_role.rbac_roles[each.value.role].name
  on_account_object {
    object_type = "INTEGRATION"
    object_name = each.value.integration_name
  }
  privileges = each.value.privileges

  depends_on = [snowflake_storage_integration.cloud_links]
}

######## users.tfvars ########
# Provision all users (Humans and Services) via the single official resource
resource "snowflake_user" "corporate_users" {
  for_each = var.users

  name         = upper(each.key)
  login_name   = each.value.login_name
  email        = each.value.email
  first_name   = each.value.first_name
  last_name    = each.value.last_name
  default_role = upper(each.value.default_role)
  disabled     = each.value.disabled
  comment      = each.value.comment
  default_namespace = each.value.default_database != null && each.value.default_schema != null ? "${upper(each.value.default_database)}.${upper(each.value.default_schema)}" : null
#  user_type        = each.value.user_type
  rsa_public_key   = each.value.rsa_public_key
  rsa_public_key_2 = each.value.rsa_public_key_2

  must_change_password = each.value.rsa_public_key == null ? true : false

  depends_on = [snowflake_schema.managed_schemas]
}



