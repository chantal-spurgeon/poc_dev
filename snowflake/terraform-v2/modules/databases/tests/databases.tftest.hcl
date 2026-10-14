# Offline tests for the databases module. They use a mock provider, so they need
# no Snowflake account and no credentials, and they change nothing.
#
#   cd modules/databases
#   terraform init -backend=false
#   terraform test
#
# Requires Terraform 1.7 or newer (mock_provider). Written without access to a
# Terraform binary, so the first run is also the first check of this file.

mock_provider "snowflake" {}

variables {
  databases = {
    DB_ONE = {
      comment = "primary"
      schemas = {
        RAW  = { comment = "raw" }
        MART = { managed_access = true, data_retention_time_days = 7 }
      }
    }

    DB_TEMP = {
      is_transient             = true
      data_retention_time_days = 0
      schemas = {
        SCRATCH = {}
      }
    }

    DB_COPY = { replica_of = "ORG.ACCT.DB_ONE" }
  }
}

run "every_definition_in_the_input_becomes_a_resource" {
  command = plan

  assert {
    condition     = sort(keys(snowflake_database.database)) == ["DB_ONE", "DB_TEMP"]
    error_message = "Primary databases should be created; the replica should not be a normal database."
  }

  assert {
    condition     = keys(snowflake_secondary_database.replica) == ["DB_COPY"]
    error_message = "DB_COPY should be created as a replica."
  }

  assert {
    condition     = snowflake_secondary_database.replica["DB_COPY"].as_replica_of == "\"ORG\".\"ACCT\".\"DB_ONE\""
    error_message = "The primary's path must be quoted one part at a time."
  }

  assert {
    condition     = sort(keys(snowflake_schema.schema)) == ["DB_ONE.MART", "DB_ONE.RAW", "DB_TEMP.SCRATCH"]
    error_message = "Every schema should be created, keyed DATABASE.SCHEMA."
  }
}

# A schema's flags are strings in provider 2.x, and a schema follows its database
# unless it says otherwise.
run "schemas_follow_their_database_and_use_string_flags" {
  command = plan

  assert {
    condition     = snowflake_schema.schema["DB_TEMP.SCRATCH"].is_transient == "true"
    error_message = "A schema in a transient database should be transient."
  }

  assert {
    condition     = snowflake_schema.schema["DB_ONE.RAW"].is_transient == "false"
    error_message = "A schema in a permanent database should be permanent."
  }

  assert {
    condition     = snowflake_schema.schema["DB_ONE.MART"].with_managed_access == "true"
    error_message = "MART asked for managed access."
  }

  assert {
    condition     = snowflake_schema.schema["DB_ONE.RAW"].with_managed_access == "false"
    error_message = "Managed access is off unless asked for."
  }
}

# ------------------------------------------------------------------------------
# Bad input must be rejected before anything is planned.
# ------------------------------------------------------------------------------
run "rejects_a_lower_case_database_name" {
  command         = plan
  variables       { databases = { db_one = {} } }
  expect_failures = [var.databases]
}

run "rejects_a_lower_case_schema_name" {
  command         = plan
  variables       { databases = { DB_ONE = { schemas = { raw = {} } } } }
  expect_failures = [var.databases]
}

run "rejects_a_snowflake_owned_database" {
  command         = plan
  variables       { databases = { SNOWFLAKE = {} } }
  expect_failures = [var.databases]
}

run "rejects_information_schema" {
  command         = plan
  variables       { databases = { DB_ONE = { schemas = { INFORMATION_SCHEMA = {} } } } }
  expect_failures = [var.databases]
}

run "rejects_more_than_one_day_of_time_travel_on_a_transient_database" {
  command         = plan
  variables       { databases = { DB_ONE = { is_transient = true, data_retention_time_days = 2 } } }
  expect_failures = [var.databases]
}

run "rejects_more_than_ninety_days_of_time_travel" {
  command         = plan
  variables       { databases = { DB_ONE = { data_retention_time_days = 91 } } }
  expect_failures = [var.databases]
}

run "rejects_a_permanent_schema_in_a_transient_database" {
  command         = plan
  variables       { databases = { DB_ONE = { is_transient = true, schemas = { RAW = { is_transient = false } } } } }
  expect_failures = [var.databases]
}

run "rejects_schemas_on_a_replica" {
  command         = plan
  variables       { databases = { DB_COPY = { replica_of = "ORG.ACCT.DB_ONE", schemas = { RAW = {} } } } }
  expect_failures = [var.databases]
}

run "rejects_a_replica_path_that_is_not_org_account_database" {
  command         = plan
  variables       { databases = { DB_COPY = { replica_of = "ACCT.DB_ONE" } } }
  expect_failures = [var.databases]
}
