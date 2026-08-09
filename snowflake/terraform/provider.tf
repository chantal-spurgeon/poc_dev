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

locals {
  private_key_path  = "~/.ssh/snowflake_key.p8"
}

# The parent provider block handles all authentication using variables or env inputs
provider "snowflake" {
  account                = var.snowflake_account
  user                   = var.snowflake_user
  authenticator          = "JWT"
  private_key            = file(local.private_key_path)
  private_key_passphrase = var.snowflake_private_key_passphrase
}

# Ensure your root variables.tf has these connection variables declared
