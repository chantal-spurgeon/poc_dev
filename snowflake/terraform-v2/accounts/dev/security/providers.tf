# This stack signs in with key-pair (JWT) authentication.
#
# The private key and its passphrase are deliberately NOT Terraform variables.
# The provider reads them from the environment, so they never appear in a
# .tfvars file, a plan, or the module inputs:
#
#   export SNOWFLAKE_PRIVATE_KEY="$(cat ~/.ssh/tf_security_svc.p8)"
#   export SNOWFLAKE_PRIVATE_KEY_PASSPHRASE="..."   # only if the key is encrypted
#
# SECURITYADMIN holds CREATE NETWORK POLICY.
provider "snowflake" {
  organization_name = var.snowflake_organization_name
  account_name      = var.snowflake_account_name
  user              = var.snowflake_user
  role              = var.snowflake_role
  authenticator     = "SNOWFLAKE_JWT"
}
