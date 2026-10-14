# This stack signs in with key-pair (JWT) authentication.
#
# The private key and its passphrase are deliberately NOT Terraform variables.
# The provider reads them from the environment, so they never appear in a
# .tfvars file, a plan, or the module inputs:
#
#   export SNOWFLAKE_PRIVATE_KEY="$(cat ~/.ssh/tf_integrations_svc.p8)"
#   export SNOWFLAKE_PRIVATE_KEY_PASSPHRASE="..."   # only if the key is encrypted
#
# Creating an integration needs the account privilege CREATE INTEGRATION, which only
# ACCOUNTADMIN holds by default. Rather than let automation sign in as ACCOUNTADMIN, this
# stack uses a custom role that holds just that one privilege. Create it once, by hand:
# see "One-time bootstrap for the stacks" in the README.
provider "snowflake" {
  organization_name = var.snowflake_organization_name
  account_name      = var.snowflake_account_name
  user              = var.snowflake_user
  role              = var.snowflake_role
  authenticator     = "SNOWFLAKE_JWT"
}
