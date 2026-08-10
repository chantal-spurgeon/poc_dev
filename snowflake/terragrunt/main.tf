# terragrunt/main.tf

locals {
  # ==============================================================================
  # 1. BASE RBAC FLATTENING LOOPS
  # ==============================================================================

  # Flatten the nested schema privileges loop into a single map
  schema_grants_base = merge([
    for role_key, role_val in var.account_roles : {
      for target_path, privileges in lookup(role_val, "schema_privileges", {}) :
      "${role_key}_SCHEMA_${target_path}" => {
        role        = upper(role_key)
        db_name     = upper(split(".", target_path)[0])
        schema_name = upper(split(".", target_path)[1])
        privileges  = privileges
      }
    }
  ]...)

  # We cannot check snowflake_schema.managed_schemas directly.
  # Instead, we evaluate that the user has provided inputs or we rely on safety checks.
  standard_schema_grants = {
    for k, v in local.schema_grants_base : k => v
    if length([for p in v.privileges : p if upper(p) != "OWNERSHIP" && upper(p) != "MODIFY"]) > 0
  }

  # Filter down to keys that explicitly request "OWNERSHIP"
  ownership_schema_grants = {
    for k, v in local.schema_grants_base : k => v
    if contains([for p in v.privileges : upper(p)], "OWNERSHIP")
  }

  # ==============================================================================
  # 2. ALL OBJECT PRIVILEGES
  # ==============================================================================
  raw_all_grants = merge(flatten([
    for role_key, role_val in var.account_roles : [
      for type, mappings in {
        "TABLES"     = lookup(role_val, "all_table_privileges", {})
        "VIEWS"      = lookup(role_val, "all_view_privileges", {})
        "PROCEDURES" = lookup(role_val, "all_procedure_privileges", {})
        "FUNCTIONS"  = lookup(role_val, "all_function_privileges", {})
        "TASKS"      = lookup(role_val, "all_task_privileges", {})
        "STAGES"     = lookup(role_val, "all_stage_privileges", {})
      } : {
        for target_path, privileges in mappings :
        "${role_key}_ALL_${type}_${target_path}" => {
          role        = upper(role_key)
          plural_type = type
          db_name     = upper(split(".", target_path)[0])
          schema_name = upper(split(".", target_path)[1])
          privileges  = privileges
        }
      }
    ]
  ])...)

  # Safely bypass local state resource constraints
  filtered_all_grants = {
    for k, v in local.raw_all_grants : k => v
    if length([for p in v.privileges : p if upper(p) != "OWNERSHIP"]) > 0
  }

  # ==============================================================================
  # 3. FUTURE OBJECT PRIVILEGES
  # ==============================================================================
  raw_future_grants = merge(flatten([
    for role_key, role_val in var.account_roles : [
      for type, mappings in {
        "TABLES"     = lookup(role_val, "future_table_privileges", {})
        "VIEWS"      = lookup(role_val, "future_view_privileges", {})
        "PROCEDURES" = lookup(role_val, "future_procedure_privileges", {})
        "FUNCTIONS"  = lookup(role_val, "future_function_privileges", {})
        "TASKS"      = lookup(role_val, "future_task_privileges", {})
        "STAGES"     = lookup(role_val, "future_stage_privileges", {})
      } : {
        for target_path, privileges in mappings :
        "${role_key}_ALL_${type}_${target_path}" => {
          role        = upper(role_key)
          plural_type = type
          db_name     = upper(split(".", target_path)[0])
          schema_name = upper(split(".", target_path)[1])
          privileges  = privileges
        }
      }
    ]
  ])...)

  # Safely bypass local state resource constraints
  filtered_future_grants = {
    for k, v in local.raw_future_grants : k => v
    if length([for p in v.privileges : p if upper(p) != "OWNERSHIP"]) > 0
  }

  # ==============================================================================
  # 4. COMPUTE, SECURITY, & IDENTITY FILTERING
  # ==============================================================================

  # Filters down to standard human user accounts
  human_users = {
    for k, v in var.users : k => v
    if lookup(v, "user_type", "PERSON") == "PERSON"
  }

  # Filters down to service profile accounts
  service_users = {
    for k, v in var.users : k => v
    if lookup(v, "user_type", "PERSON") == "SERVICE"
  }

  # Filters down to AWS storage integrations
  aws_integrations = {
    for k, v in var.storage_integrations : k => v
    if upper(lookup(v, "provider", "")) == "S3" || upper(lookup(v, "provider", "")) == "AWS"
  }

  # Filters down to Azure storage integrations
  azure_integrations = {
    for k, v in var.storage_integrations : k => v
    if upper(lookup(v, "provider", "")) == "AZURE"
  }

  # Filters down to Google Cloud storage integrations
  gcs_integrations = {
    for k, v in var.storage_integrations : k => v
    if upper(lookup(v, "provider", "")) == "GCS" || upper(lookup(v, "provider", "")) == "GOOGLE"
  }
}

# ==============================================================================
# 1. PRIMARY DATABASES
# ==============================================================================
resource "snowflake_database" "managed_dbs" {
  for_each = { for k, v in var.databases : k => v if !lookup(v, "is_replica", false) }

  name                        = upper(each.key)
  comment                     = lookup(each.value, "comment", null)
  data_retention_time_in_days = lookup(each.value, "data_retention_time_days", 1)
  is_transient                = lookup(each.value, "is_transient", false)
}

# ==============================================================================
# 2. REPLICATED SECONDARY DATABASES
# ==============================================================================
resource "snowflake_secondary_database" "managed_replicas" {
  for_each = { for k, v in var.databases : k => v if lookup(v, "is_replica", false) }

  name           = upper(each.key)
  comment        = lookup(each.value, "comment", null)
  as_replica_of  = each.value.primary_database_path
}

# ==============================================================================
# 3. NESTED SCHEMAS
# ==============================================================================
resource "snowflake_schema" "managed_schemas" {
  # Use lookup() on 'schemas' to return an empty map if a database entry omits it entirely
  for_each = merge([
    for db_key, db_val in var.databases : {
      for schema_key, schema_val in lookup(db_val, "schemas", {}) :
      "${db_key}.${schema_key}" => {
        database       = upper(db_key)
        schema         = schema_key
        comment        = lookup(schema_val, "comment", null)
        is_transient   = lookup(schema_val, "is_transient", false)
        managed_access = lookup(schema_val, "managed_access", false)
      }
    }
  ]...)

  # Pass the upper-cased parent string name directly instead of
  # digging into the local resource map index. This lets other stacks initialize safely!
  database            = each.value.database
  name                = upper(each.value.schema)
  comment             = each.value.comment
  is_transient        = each.value.is_transient
  with_managed_access = each.value.managed_access

  # Explicit lifecycle safety link to ensure databases exist first during the DB run
  depends_on = [snowflake_database.managed_dbs]
}


# ==============================================================================
# VIRTUAL WAREHOUSES
# ==============================================================================
resource "snowflake_warehouse" "managed_whs" {
  for_each = var.warehouses

  name                = upper(each.key)
  warehouse_size      = lookup(each.value, "warehouse_size", "XSMALL")
  auto_suspend        = lookup(each.value, "auto_suspend", 600)
  auto_resume         = lookup(each.value, "auto_resume", true)
  initially_suspended = lookup(each.value, "initially_suspended", true)
  comment             = lookup(each.value, "comment", null)

  # Protects deployment from crashing if optional scaling parameters are absent
  warehouse_type      = lookup(each.value, "warehouse_type", "STANDARD")
  min_cluster_count   = lookup(each.value, "min_cluster_count", 1)
  max_cluster_count   = lookup(each.value, "max_cluster_count", 1)
  scaling_policy      = lookup(each.value, "scaling_policy", "STANDARD")
}


# ==============================================================================
# SECURITY NETWORK POLICIES
# ==============================================================================
resource "snowflake_network_policy" "security_policies" {
  for_each = var.network_policies

  name            = upper(each.key)
  allowed_ip_list = each.value.allowed_ip_list

  # Protects deployment from crashing if optional keys are omitted
  blocked_ip_list = lookup(each.value, "blocked_ip_list", null)
  comment         = lookup(each.value, "comment", null)
}


# ==============================================================================
# AWS S3 STORAGE INTEGRATIONS
# ==============================================================================
resource "snowflake_storage_integration_aws" "cloud_links" {
  for_each = local.aws_integrations

  name    = upper(each.key)
  enabled = true
  comment = lookup(each.value, "comment", null)

  storage_provider          = "S3"
  storage_allowed_locations = each.value.storage_allowed_locations
  storage_blocked_locations = lookup(each.value, "storage_blocked_locations", null)
  storage_aws_role_arn      = each.value.storage_aws_role_arn
}

# ==============================================================================
# AZURE STORAGE INTEGRATIONS
# ==============================================================================
resource "snowflake_storage_integration_azure" "cloud_links" {
  for_each = local.azure_integrations

  name    = upper(each.key)
  enabled = true
  comment = lookup(each.value, "comment", null)

  storage_allowed_locations = each.value.storage_allowed_locations
  storage_blocked_locations = lookup(each.value, "storage_blocked_locations", null)

  # Secured with lookup fallback to prevent structural validation crashes
  azure_tenant_id           = lookup(each.value, "azure_tenant_id", null)
}

# ==============================================================================
# GOOGLE CLOUD STORAGE (GCS) INTEGRATIONS
# ==============================================================================
resource "snowflake_storage_integration_gcs" "cloud_links" {
  for_each = local.gcs_integrations

  name    = upper(each.key)
  enabled = true
  comment = lookup(each.value, "comment", null)

  storage_allowed_locations = each.value.storage_allowed_locations
  storage_blocked_locations = lookup(each.value, "storage_blocked_locations", null)
}


# ==============================================================================
# 1. CUSTOM ACCOUNT ROLES
# ==============================================================================
resource "snowflake_account_role" "rbac_roles" {
  for_each = {
    for role_key, role_val in var.account_roles : role_key => role_val
    if !contains(["ACCOUNTADMIN", "SYSADMIN", "SECURITYADMIN", "USERADMIN", "PUBLIC"], upper(role_key))
  }
  name    = upper(each.key)
  comment = lookup(each.value, "comment", null)
}

# ==============================================================================
# 2. ROLE-TO-ROLE HIERARCHIES
# ==============================================================================
resource "snowflake_grant_account_role" "role_to_role_grants" {
  for_each = merge([
    for parent_role, configurations in var.account_roles : {
      for child_role in lookup(configurations, "granted_roles", []) :
      "${parent_role}_INHERITS_${child_role}" => {
        parent_name = upper(parent_role)
        child_name  = upper(child_role)
      }
    }
  ]...)

  # Pass strings directly. This prevents validation crashes
  # when resources don't exist in the active runner's state.
  parent_role_name = each.value.parent_name
  role_name        = each.value.child_name

  depends_on = [snowflake_account_role.rbac_roles]
}

# ==============================================================================
# 3. USER-TO-ROLE ASSIGNMENTS
# ==============================================================================
resource "snowflake_grant_account_role" "user_to_role_grants" {
  for_each = merge(flatten([
    for role_name, configurations in var.account_roles : {
      for user_name in lookup(configurations, "granted_users", []) :
      "${user_name}_ASSIGNED_TO_${role_name}" => {
        role_target = upper(role_name)
        user_target = upper(user_name)
      }
    }
  ])...)

  # No resource index map lookup logic to crash validation paths
  role_name = each.value.role_target
  user_name = each.value.user_target

  depends_on = [snowflake_account_role.rbac_roles]
}

# ==============================================================================
# 4. ACCOUNT-LEVEL PRIVILEGES
# ==============================================================================
resource "snowflake_grant_privileges_to_account_role" "account_grants" {
  for_each = merge([
    for role_key, role_val in var.account_roles : {
      for privilege in lookup(role_val, "account_privileges", []) :
      "${role_key}_ACCOUNT_${privilege}" => {
        role      = upper(role_key)
        privilege = privilege
      }
    }
  ]...)

  account_role_name = each.value.role
  on_account        = true
  privileges        = [each.value.privilege]

  depends_on = [snowflake_account_role.rbac_roles]
}

# ==============================================================================
# 5. DATABASE-LEVEL PRIVILEGES
# ==============================================================================
resource "snowflake_grant_privileges_to_account_role" "database_grants" {
  for_each = merge([
    for role_key, role_val in var.account_roles : {
      for db_key, privileges in lookup(role_val, "database_privileges", {}) :
      "${role_key}_DB_${db_key}" => {
        role       = upper(role_key)
        db_name    = upper(db_key)
        privileges = privileges
      }
    }
  ]...)

  account_role_name = each.value.role
  on_account_object {
    object_type = "DATABASE"
    object_name = each.value.db_name
  }
  privileges = each.value.privileges

  depends_on = [snowflake_account_role.rbac_roles]
}

# ==============================================================================
# 6. STANDARD SCHEMA PRIVILEGES
# ==============================================================================
resource "snowflake_grant_privileges_to_account_role" "schema_grants" {
  for_each = local.standard_schema_grants

  account_role_name = each.value.role
  on_schema {
    schema_name = "\"${each.value.db_name}\".\"${each.value.schema_name}\""
  }

  privileges = [
    for p in each.value.privileges : p
    if upper(p) != "OWNERSHIP" && upper(p) != "MODIFY"
  ]

  depends_on = [snowflake_account_role.rbac_roles]
}

# ==============================================================================
# 7. SCHEMA OWNERSHIP TRANSFERS
# ==============================================================================
resource "snowflake_grant_ownership" "schema_ownership" {
  for_each = local.ownership_schema_grants

  account_role_name   = each.value.role
  outbound_privileges = "COPY"

  on {
    object_type = "SCHEMA"
    object_name = "\"${each.value.db_name}\".\"${each.value.schema_name}\""
  }

  depends_on = [snowflake_account_role.rbac_roles]
}

# ==============================================================================
# 8. BULK CURRENT OBJECT GRANTS (TABLES, VIEWS, ETC.)
# ==============================================================================
resource "snowflake_grant_privileges_to_account_role" "bulk_all_grants" {
  for_each = local.filtered_all_grants

  account_role_name = each.value.role
  on_schema_object {
    all {
      object_type_plural = each.value.plural_type
      # Ensure strict upper-cased parsing to match Snowflake's catalog storage engine
      in_schema          = "\"${upper(each.value.db_name)}\".\"${upper(each.value.schema_name)}\""
    }
  }

  privileges = [
    for p in each.value.privileges : p
    if upper(p) != "OWNERSHIP" && !(
      each.value.plural_type == "VIEWS" && contains(["INSERT", "DELETE", "UPDATE", "MODIFY"], upper(p))
    )
  ]

  depends_on = [snowflake_account_role.rbac_roles]
}

# ==============================================================================
# 9. BULK FUTURE OBJECT PRIVILEGES
# ==============================================================================
resource "snowflake_grant_privileges_to_account_role" "bulk_future_grants" {
  for_each = local.filtered_future_grants

  account_role_name = each.value.role
  on_schema_object {
    future {
      object_type_plural = each.value.plural_type
      # Ensure strict upper-cased parsing to match Snowflake's catalog storage engine
      in_schema          = "\"${upper(each.value.db_name)}\".\"${upper(each.value.schema_name)}\""
    }
  }

  privileges = [
    for p in each.value.privileges : p
    if upper(p) != "OWNERSHIP" && !(
      each.value.plural_type == "VIEWS" && contains(["INSERT", "DELETE", "UPDATE", "MODIFY"], upper(p))
    )
  ]

  depends_on = [snowflake_account_role.rbac_roles]
}

# ==============================================================================
# 10. VIRTUAL WAREHOUSE PRIVILEGES
# ==============================================================================
resource "snowflake_grant_privileges_to_account_role" "warehouse_grants" {
  for_each = merge([
    for role_key, role_val in var.account_roles : {
      for wh_key, privileges in lookup(role_val, "warehouse_privileges", {}) :
      "${role_key}_WH_${wh_key}" => {
        role       = upper(role_key)
        wh_name    = upper(wh_key)
        privileges = privileges
      }
    }
  ]...)

  account_role_name = each.value.role
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = each.value.wh_name
  }
  privileges = each.value.privileges

  depends_on = [snowflake_account_role.rbac_roles]
}

# ==============================================================================
# 11. STORAGE INTEGRATION-LEVEL PRIVILEGES
# ==============================================================================
resource "snowflake_grant_privileges_to_account_role" "integration_grants" {
  for_each = merge([
    for role_key, role_val in var.account_roles : {
      # Use lookup() fallback to protect against empty maps during zero-state evaluations
      for integration_key, privileges in lookup(role_val, "integration_privileges", {}) :
      "${role_key}_INT_${integration_key}" => {
        role             = upper(role_key)
        integration_name = upper(integration_key)
        privileges       = privileges
      }
    }
  ]...)

  # Pass the upper-cased key string directly instead of map digging
  account_role_name = each.value.role

  on_account_object {
    object_type = "INTEGRATION"
    object_name = each.value.integration_name
  }
  privileges = each.value.privileges

  # Only depend on roles created inside this active RBAC state engine
  depends_on = [snowflake_account_role.rbac_roles]
}


# ==============================================================================
# 1. STANDARD HUMAN USER ACCOUNTS (USER_TYPE = PERSON)
# ==============================================================================
resource "snowflake_user" "corporate_users" {
  for_each = local.human_users

  name         = upper(each.key)
  login_name   = each.value.login_name
  email        = each.value.email
  first_name   = lookup(each.value, "first_name", null)
  last_name    = lookup(each.value, "last_name", null)
  disabled     = lookup(each.value, "disabled", false)
  comment      = lookup(each.value, "comment", null)

  # Safe lookup prevents validation crashes if default_role is entirely omitted
  default_role = lookup(each.value, "default_role", null) != null ? upper(each.value.default_role) : null

  default_secondary_roles_option = contains(lookup(each.value, "default_secondary_roles", []), "ALL") ? "ALL" : "NONE"

  # Checks for a direct string 'default_namespace' fallback
  # or combines individual db/schema keys if present
  default_namespace = lookup(each.value, "default_namespace", null) != null ? upper(each.value.default_namespace) : (
    lookup(each.value, "default_database", null) != null && lookup(each.value, "default_schema", null) != null ? "${upper(each.value.default_database)}.${upper(each.value.default_schema)}" : null
  )

  # Humans using passwords must change them on first login; key-pair users do not
  must_change_password = lookup(each.value, "rsa_public_key", null) == null ? true : false

  lifecycle {
    ignore_changes = [default_secondary_roles_option]
  }
}

# ==============================================================================
# 2. DEDICATED MACHINE SERVICE ACCOUNTS (USER_TYPE = SERVICE)
# ==============================================================================
resource "snowflake_service_user" "service_accounts" {
  for_each = local.service_users

  name       = upper(each.key)
  login_name = each.value.login_name
  email      = each.value.email
  disabled   = lookup(each.value, "disabled", false)
  comment    = lookup(each.value, "comment", null)

  default_role = lookup(each.value, "default_role", null) != null ? upper(each.value.default_role) : null

  default_secondary_roles_option = contains(lookup(each.value, "default_secondary_roles", []), "ALL") ? "ALL" : "NONE"

  default_namespace = lookup(each.value, "default_namespace", null) != null ? upper(each.value.default_namespace) : (
    lookup(each.value, "default_database", null) != null && lookup(each.value, "default_schema", null) != null ? "${upper(each.value.default_database)}.${upper(each.value.default_schema)}" : null
  )

  # Key-Pair Cryptography attributes supported natively by Service Users
  rsa_public_key   = lookup(each.value, "rsa_public_key", null)
  rsa_public_key_2 = lookup(each.value, "rsa_public_key_2", null)

  lifecycle {
    ignore_changes = [default_secondary_roles_option]
  }
}







