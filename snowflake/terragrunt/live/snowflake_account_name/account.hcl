# terragrunt/snowflake_account_name/account.hcl

locals {
  # Global static configurations
  snowflake_account = "NXMEPIV-QGB61660"
  authenticator     = "SNOWFLAKE_JWT"
  user              = get_env("TF_VAR_snowflake_user", "")
  role              = "ACCOUNTADMIN"

  # Securely fetch secrets from local machine or CI/CD runner environment variables
  # get_env("ENV_VAR_NAME", "DEFAULT_FALLBACK")
  private_key       = get_env("TF_VAR_snowflake_private_key", "")
  private_key_pass  = get_env("TF_VAR_snowflake_private_key_passphrase", "")
}
