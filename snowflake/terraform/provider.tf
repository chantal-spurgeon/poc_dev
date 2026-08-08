# ../provider.tf (Parent path root file)

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = "~> 0.94.0"
    }
  }
}

# The parent provider block handles all authentication using variables or env inputs
provider "snowflake" {
#  organization_name      = var.snowflake_organization
#  account_name           = var.snowflake_account
  user                   = var.snowflake_user
#  authenticator          = var.snowflake_authenticator
  private_key            = var.snowflake_private_key
  private_key_passphrase = var.snowflake_private_key_passphrase
}

# Ensure your root variables.tf has these connection variables declared
