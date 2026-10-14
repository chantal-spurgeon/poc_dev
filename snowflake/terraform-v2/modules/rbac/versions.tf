terraform {
  # >= 1.11 gives native S3 state locking (use_lockfile) and lets variable
  # validation refer to other variables.
  required_version = ">= 1.11.0"

  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = ">= 2.19.0, < 3.0.0"
    }
  }
}
