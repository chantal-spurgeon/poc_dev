# ../provider.tf (Parent path root file)

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = "~> 2.19.0" # Leverages the absolute latest version features
    }
  }
}

locals {
  private_key  = "~/.ssh/snowflake_key.p8"
}

# The parent provider block handles all authentication using variables or env inputs
provider "snowflake" {
  account                = var.snowflake_account
  user                   = var.snowflake_user
  authenticator          = "SNOWFLAKE_JWT"
  private_key            = file(local.private_key)
  private_key_passphrase = var.snowflake_private_key_passphrase

  experimental_features_enabled = ["PROVIDER_CONFIGURATION_ACCOUNT_FALLBACK"]
  preview_features_enabled = ["snowflake_storage_integration_resource"]
}

# Ensure your root variables.tf has these connection variables declared
