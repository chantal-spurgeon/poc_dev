# Offline tests for the rbac module. They use a mock provider, so they need no
# Snowflake account and no credentials, and they change nothing.
#
#   cd modules/rbac
#   terraform init -backend=false
#   terraform test
#
# Requires Terraform 1.7 or newer (mock_provider). Written without access to a
# Terraform binary, so the first run is also the first check of this file.

mock_provider "snowflake" {}

variables {
  account_roles = {
    SYSADMIN = { inherits = ["PRODUCER"] }

    PRODUCER = {
      comment    = "test role"
      users      = ["BANGCHAN"]
      databases  = { DB_ONE = ["USAGE"] }
      warehouses = { WH_ONE = ["USAGE", "OPERATE"] }
      schemas = {
        "DB_ONE.SCH_ONE" = {
          privileges = ["USAGE"]
          objects = {
            TABLES = { current = ["SELECT"], future = ["SELECT"] }
            VIEWS  = { current = ["SELECT"] }
          }
        }
        "DB_ONE.SCH_OWNED" = { owner = true }
      }
    }

    MONITOR = { database_roles = ["SNOWFLAKE.SECURITY_VIEWER"] }
  }
}

# ------------------------------------------------------------------------------
# Regression test for the bug in the old code: grants on schemas and objects
# were silently skipped because of a upper/lower case mismatch. Every grant
# written in the variables above must produce a resource.
# ------------------------------------------------------------------------------
run "every_grant_in_the_input_becomes_a_resource" {
  command = plan

  assert {
    condition     = sort(keys(snowflake_account_role.role)) == ["MONITOR", "PRODUCER"]
    error_message = "Custom roles should be created; the system role SYSADMIN should not be."
  }

  assert {
    condition     = keys(snowflake_grant_account_role.inheritance) == ["SYSADMIN<-PRODUCER"]
    error_message = "SYSADMIN should inherit PRODUCER."
  }

  assert {
    condition     = keys(snowflake_grant_account_role.to_user) == ["PRODUCER:BANGCHAN"]
    error_message = "PRODUCER should be granted to BANGCHAN."
  }

  assert {
    condition     = keys(snowflake_grant_database_role.to_role) == ["MONITOR:SNOWFLAKE.SECURITY_VIEWER"]
    error_message = "The database role should be granted to MONITOR."
  }

  assert {
    condition = sort(keys(snowflake_grant_privileges_to_account_role.account_object)) == [
      "PRODUCER:DATABASE:DB_ONE",
      "PRODUCER:WAREHOUSE:WH_ONE",
    ]
    error_message = "Database and warehouse grants are missing."
  }

  assert {
    condition     = keys(snowflake_grant_privileges_to_account_role.schema) == ["PRODUCER:DB_ONE.SCH_ONE"]
    error_message = "The schema grant is missing. (SCH_OWNED has no privileges, so it gets none.)"
  }

  assert {
    condition = sort(keys(snowflake_grant_privileges_to_account_role.schema_objects_current)) == [
      "PRODUCER:DB_ONE.SCH_ONE:TABLES",
      "PRODUCER:DB_ONE.SCH_ONE:VIEWS",
    ]
    error_message = "Grants on existing tables and views are missing."
  }

  assert {
    condition     = keys(snowflake_grant_privileges_to_account_role.schema_objects_future) == ["PRODUCER:DB_ONE.SCH_ONE:TABLES"]
    error_message = "Only tables have future grants in this input; views have none."
  }

  assert {
    condition     = keys(snowflake_grant_ownership.schema) == ["PRODUCER:DB_ONE.SCH_OWNED"]
    error_message = "Ownership of SCH_OWNED should go to PRODUCER."
  }

  assert {
    condition     = snowflake_grant_ownership.schema["PRODUCER:DB_ONE.SCH_OWNED"].on[0].object_name == "\"DB_ONE\".\"SCH_OWNED\""
    error_message = "Schema names must be quoted one part at a time."
  }
}

# ------------------------------------------------------------------------------
# Bad input must be rejected before anything is planned.
# ------------------------------------------------------------------------------
run "rejects_a_lower_case_role_name" {
  command         = plan
  variables       { account_roles = { producer = {} } }
  expect_failures = [var.account_roles]
}

run "rejects_a_schema_not_written_as_database_dot_schema" {
  command         = plan
  variables       { account_roles = { PRODUCER = { schemas = { ONLY_ONE_PART = { privileges = ["USAGE"] } } } } }
  expect_failures = [var.account_roles]
}

run "rejects_ownership_as_a_privilege" {
  command         = plan
  variables       { account_roles = { PRODUCER = { schemas = { "DB.SCH" = { privileges = ["OWNERSHIP"] } } } } }
  expect_failures = [var.account_roles]
}

run "rejects_insert_on_views" {
  command = plan
  variables {
    account_roles = {
      PRODUCER = { schemas = { "DB.SCH" = { objects = { VIEWS = { current = ["INSERT"] } } } } }
    }
  }
  expect_failures = [var.account_roles]
}

run "rejects_an_unknown_object_type" {
  command = plan
  variables {
    account_roles = {
      PRODUCER = { schemas = { "DB.SCH" = { objects = { WIDGETS = { current = ["SELECT"] } } } } }
    }
  }
  expect_failures = [var.account_roles]
}

run "rejects_inheriting_a_role_that_does_not_exist" {
  command         = plan
  variables       { account_roles = { PRODUCER = { inherits = ["NO_SUCH_ROLE"] } } }
  expect_failures = [var.account_roles]
}

run "rejects_inheriting_securityadmin" {
  command         = plan
  variables       { account_roles = { PRODUCER = { inherits = ["SECURITYADMIN"] } } }
  expect_failures = [var.account_roles]
}

run "rejects_granting_accountadmin_to_a_user" {
  command         = plan
  variables       { account_roles = { ACCOUNTADMIN = { users = ["SOMEONE"] } } }
  expect_failures = [var.account_roles]
}

run "rejects_manage_grants" {
  command         = plan
  variables       { account_roles = { PRODUCER = { account_privileges = ["MANAGE GRANTS"] } } }
  expect_failures = [var.account_roles]
}
