terraform {
  required_version = ">= 1.5.0"
  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = "~> 0.94.0" # Use the latest stable version
    }
  }
}

# The default provider handles Org-level actions (must run as ORGADMIN)
provider "snowflake" {
  organization_name = var.snowflake_organization
  account_name      = var.snowflake_primary_account
  user              = var.snowflake_org_user
  authenticator     = "SNOWFLAKE_JWT"
  private_key       = var.snowflake_org_private_key
}
