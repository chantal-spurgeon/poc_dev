terraform {
  required_version = ">= 1.11.0"

  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = "~> 2.19.0"
    }
  }

  # Where this stack's state lives. The bucket and key are not hard-coded here;
  # they come from backend.hcl:   terraform init -backend-config=backend.hcl
  backend "s3" {}
}
