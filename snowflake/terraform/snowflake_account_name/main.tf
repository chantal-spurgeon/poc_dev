# Call the parent directory module where your logic lives
# accounts/dev_account/main.tf (Local subfolder file)

module "snowflake_infrastructure" {
  source = "../" # Points back to your root directory logic

  # This maps the parent variables block to your local connection credentials
  snowflake_organization           = var.snowflake_organization
  snowflake_account                = var.snowflake_account
  snowflake_user                   = var.snowflake_user
  snowflake_authenticator          = var.snowflake_authenticator
  snowflake_private_key            = var.snowflake_private_key
  snowflake_private_key_passphrase = var.snowflake_private_key_passphrase

  # Forward your structural resource configurations
  databases            = var.databases
  warehouses           = var.warehouses
  account_roles        = var.account_roles
  users                = var.users
  network_policies     = var.network_policies
  storage_integrations = var.storage_integrations
}
