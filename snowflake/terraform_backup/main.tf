locals {
   # Flatten the nested loops into a single map
    schema_grants_base = merge([
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

    standard_schema_grants = {
      for k, v in local.schema_grants_base : k => v
      if contains(keys(snowflake_schema.managed_schemas), "${v.db_name}.${v.schema_name}") &&
      length([for p in v.privileges : p if upper(p) != "OWNERSHIP" && upper(p) != "MODIFY"]) > 0
    }

   # Filter down to keys that explicitly request "OWNERSHIP"
   ownership_schema_grants = {
     for k, v in local.schema_grants_base : k => v
     if contains([for p in v.privileges : upper(p)], "OWNERSHIP")
   }

  # Your existing raw 'all' grants flattening loop
  raw_all_grants = merge(flatten([
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
          plural_type = type
          db_name     = upper(split(".", target_path)[0])
          schema_name = upper(split(".", target_path)[1])
          privileges  = privileges
        }
      }
    ]
  ])...)

  # Prevent the loop from executing before the schema exists in state,
  # and filter out empty collections
  filtered_all_grants = {
    for k, v in local.raw_all_grants : k => v
    if contains(keys(snowflake_schema.managed_schemas), "${v.db_name}.${v.schema_name}") &&
    length([for p in v.privileges : p if upper(p) != "OWNERSHIP"]) > 0
  }

  # Flatten the raw variable maps
  raw_future_grants = merge(flatten([
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

  # Filter out entries targeting schemas that don't exist yet, or have empty privileges
  filtered_future_grants = {
    for k, v in local.raw_future_grants : k => v
    if contains(keys(snowflake_schema.managed_schemas), "${v.db_name}.${v.schema_name}") &&
    length([for p in v.privileges : p if upper(p) != "OWNERSHIP"]) > 0
  }

  # Filters down to standard human user accounts
  human_users = {
    for k, v in var.users : k => v
    if lookup(v, "user_type", "PERSON") == "PERSON"
  }

  service_users = {
    for k, v in var.users : k => v
    if lookup(v, "user_type", "PERSON") == "SERVICE"
  }

  # Filters down to AWS storage integrations
  aws_integrations = {
    for k, v in var.storage_integrations : k => v
    if upper(v.provider) == "S3" || upper(v.provider) == "AWS"
  }

  # Filters down to Azure storage integrations (if any exist in your tfvars)
  azure_integrations = {
    for k, v in var.storage_integrations : k => v
    if upper(v.provider) == "AZURE"
  }

  # Filters down to Google Cloud storage integrations (if any exist in your tfvars)
  gcs_integrations = {
    for k, v in var.storage_integrations : k => v
    if upper(v.provider) == "GCS" || upper(v.provider) == "GOOGLE"
  }
}

############################################################################################
######## databases.tfvars ########
############################################################################################
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


############################################################################################
######## warehouses.tfvars ########
############################################################################################
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


############################################################################################
######## security.tfvars ########
############################################################################################
# Provision Network Protection Policies
resource "snowflake_network_policy" "security_policies" {
  for_each = var.network_policies
  name            = upper(each.key)
  allowed_ip_list = each.value.allowed_ip_list
  blocked_ip_list = each.value.blocked_ip_list
  comment         = each.value.comment
}


############################################################################################
######## integrations.tfvars ########
############################################################################################
# Provision Secure Storage Connectors
# AWS S3 Storage Integrations
resource "snowflake_storage_integration_aws" "cloud_links" {
  for_each = local.aws_integrations
  name    = upper(each.key)
  enabled = true
  comment = lookup(each.value, "comment", null)

  # Add this exact required string configuration argument
  storage_provider          = "S3"
  storage_allowed_locations = each.value.storage_allowed_locations
  storage_blocked_locations = lookup(each.value, "storage_blocked_locations", null)
  storage_aws_role_arn      = each.value.storage_aws_role_arn
}


# Azure Storage Integrations (Optional: Safe to include even if empty)
resource "snowflake_storage_integration_azure" "cloud_links" {
  for_each = local.azure_integrations
  name                      = upper(each.key)
  enabled                   = true
  comment                   = lookup(each.value, "comment", null)
  storage_allowed_locations = each.value.storage_allowed_locations
  storage_blocked_locations = lookup(each.value, "storage_blocked_locations", null)

  # Azure Specific parameters
  azure_tenant_id           = each.value.azure_tenant_id
}

# Dedicated Google Cloud Storage (GCS) Integrations
resource "snowflake_storage_integration_gcs" "cloud_links" {
  for_each = local.gcs_integrations

  name                      = upper(each.key)
  enabled                   = true
  comment                   = lookup(each.value, "comment", null)
  storage_allowed_locations = each.value.storage_allowed_locations
  storage_blocked_locations = lookup(each.value, "storage_blocked_locations", null)
}


############################################################################################
######## rbac.tfvars ########
############################################################################################
# Provision the core roles
resource "snowflake_account_role" "rbac_roles" {
  # FIX: Filter out native, system-defined Snowflake roles
  for_each = {
    for role_key, role_val in var.account_roles : role_key => role_val
    if !contains(["ACCOUNTADMIN", "SYSADMIN", "SECURITYADMIN", "USERADMIN", "PUBLIC"], upper(role_key))
  }
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

  # The role receiving the permissions (The Parent)
  # Uses a dynamic try() lookup because native roles like SYSADMIN won't exist in rbac_roles
  parent_role_name = try(snowflake_account_role.rbac_roles[each.value.parent_name].name, each.value.parent_name)

  # The role whose permissions are being inherited (The Child)
  # Uses a dynamic try() lookup so it safely matches both custom and system roles
  role_name        = try(snowflake_account_role.rbac_roles[each.value.child_name].name, each.value.child_name)
}

# Flatten and map the User-to-Role assignments
# User-to-Role assignments matrix
resource "snowflake_grant_account_role" "user_to_role_grants" {
  for_each = merge(flatten([
    for role_name, configurations in var.account_roles : {
      for user_name in configurations.granted_users :
      "${user_name}_ASSIGNED_TO_${role_name}" => {
        # Keep lowercase key for resource block lookups, but upper for raw fallbacks
        role_target     = upper(role_name)
        user_target     = upper(user_name)
        user_lookup_key = lower(user_name)
      }
    }
  ])...)

  # Safe lookup for the target RBAC role name
  role_name = snowflake_account_role.rbac_roles[each.value.role_target].name

  # Safely read the resource name from whichever pool the user belongs to.
  # If the user is unmanaged or a native system user, fall back to the raw string.
  user_name = try(
    snowflake_user.corporate_users[each.value.user_lookup_key].name,
    snowflake_service_user.service_accounts[each.value.user_lookup_key].name,
    each.value.user_target
  )

  # Depend on both human and service user resource blocks
  depends_on = [
    snowflake_user.corporate_users,
    snowflake_service_user.service_accounts
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
# Standard Schema-Level Privileges (USAGE, CREATE TABLE, etc.)
resource "snowflake_grant_privileges_to_account_role" "schema_grants" {
  for_each = local.standard_schema_grants
  account_role_name = snowflake_account_role.rbac_roles[each.value.role].name
  on_schema {
    schema_name = "\"${each.value.db_name}\".\"${each.value.schema_name}\""
  }

  # Filter out OWNERSHIP so only standard privileges pass through
    privileges = [
      for p in each.value.privileges : p
      if upper(p) != "OWNERSHIP" && upper(p) != "MODIFY"
    ]

  depends_on = [snowflake_schema.managed_schemas]
}

# Dedicated Schema-Level Ownership Transfers
resource "snowflake_grant_ownership" "schema_ownership" {
  # Meta-arguments (for_each, depends_on) belong right at the top
  for_each   = local.ownership_schema_grants
  depends_on = [snowflake_schema.managed_schemas]

  # Main target configuration
  account_role_name = snowflake_account_role.rbac_roles[each.value.role].name

  # Outbound privilege behavior: COPY keeps downstream grants; REVOKE wipes them
  outbound_privileges = "COPY"

  # Target assignment configuration block
  on {
    object_type = "SCHEMA"
    object_name = "\"${each.value.db_name}\".\"${each.value.schema_name}\""
  }
}

# Bulk Current Objects Grants (Handles TABLES, VIEWS, etc.)
resource "snowflake_grant_privileges_to_account_role" "bulk_all_grants" {
  # Use the pre-filtered timing-safe map
  for_each = local.filtered_all_grants
  account_role_name = snowflake_account_role.rbac_roles[each.value.role].name

  # Ensure your target parameters point securely to current objects
  on_schema_object {
    all {
      object_type_plural = each.value.plural_type
      in_schema          = "\"${each.value.db_name}\".\"${each.value.schema_name}\""
    }
  }

  # FIX: Strip OWNERSHIP *AND* invalid view modification privileges completely
  privileges = [
    for p in each.value.privileges : p
    if upper(p) != "OWNERSHIP" && !(
      each.value.plural_type == "VIEWS" && contains(["INSERT", "DELETE", "UPDATE", "MODIFY"], upper(p))
    )
  ]

  depends_on = [snowflake_schema.managed_schemas]
}

# Bulk Future Object Privileges (FUTURE Tables, Views, Stages, Tasks, etc.)
resource "snowflake_grant_privileges_to_account_role" "bulk_future_grants" {
  # Use the pre-filtered timing-safe map
  for_each = local.filtered_future_grants
  account_role_name = snowflake_account_role.rbac_roles[each.value.role].name
  on_schema_object {
    future {
      object_type_plural = each.value.plural_type
      in_schema          = "\"${each.value.db_name}\".\"${each.value.schema_name}\""
    }
  }

  # Strip OWNERSHIP *AND* invalid view modification privileges completely
  privileges = [
    for p in each.value.privileges : p
    if upper(p) != "OWNERSHIP" && !(
      each.value.plural_type == "VIEWS" && contains(["INSERT", "DELETE", "UPDATE", "MODIFY"], upper(p))
    )
  ]

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

  depends_on = [
    snowflake_storage_integration_aws.cloud_links,
    snowflake_storage_integration_azure.cloud_links,
    snowflake_storage_integration_gcs.cloud_links
  ]
}


############################################################################################
######## users.tfvars ########
############################################################################################
# Provision all users (Humans and Services) via the single official resource
# Standard Human User Accounts (USER_TYPE = PERSON)
resource "snowflake_user" "corporate_users" {
  for_each = local.human_users
  name         = upper(each.key)
  login_name   = each.value.login_name
  email        = each.value.email
  first_name   = lookup(each.value, "first_name", null)
  last_name    = lookup(each.value, "last_name", null)
  disabled     = lookup(each.value, "disabled", false)
  comment      = lookup(each.value, "comment", null)

  default_role            = each.value.default_role != null ? upper(each.value.default_role) : null
  #default_secondary_roles = lookup(each.value, "default_secondary_roles", [])
  default_secondary_roles_option = contains(lookup(each.value, "default_secondary_roles", []), "ALL") ? "ALL" : "NONE"
  default_namespace = lookup(each.value, "default_database", null) != null && lookup(each.value, "default_schema", null) != null ? "${upper(each.value.default_database)}.${upper(each.value.default_schema)}" : null

  # Humans using passwords must change them on first login; key-pair users do not
  must_change_password = lookup(each.value, "rsa_public_key", null) == null ? true : false

  lifecycle {
    ignore_changes = [default_secondary_roles_option]
  }

  depends_on = [snowflake_schema.managed_schemas]
}

# Dedicated Machine Service Accounts (USER_TYPE = SERVICE)
resource "snowflake_service_user" "service_accounts" {
  for_each = local.service_users
  name       = upper(each.key)
  login_name = each.value.login_name
  email      = each.value.email
  disabled   = lookup(each.value, "disabled", false)
  comment    = lookup(each.value, "comment", null)

  default_role            = each.value.default_role != null ? upper(each.value.default_role) : null
  #default_secondary_roles = lookup(each.value, "default_secondary_roles", [])
  default_secondary_roles_option = contains(lookup(each.value, "default_secondary_roles", []), "ALL") ? "ALL" : "NONE"
  default_namespace = lookup(each.value, "default_database", null) != null && lookup(each.value, "default_schema", null) != null ? "${upper(each.value.default_database)}.${upper(each.value.default_schema)}" : null

  # Key-Pair Cryptography attributes supported natively by Service Users
  rsa_public_key   = lookup(each.value, "rsa_public_key", null)
  rsa_public_key_2 = lookup(each.value, "rsa_public_key_2", null)

  lifecycle {
    ignore_changes = [default_secondary_roles_option]
  }

  depends_on = [snowflake_schema.managed_schemas]
}






