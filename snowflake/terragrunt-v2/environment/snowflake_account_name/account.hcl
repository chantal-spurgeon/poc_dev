# environment/snowflake_account_name/account.hcl

locals {
  # Global static configurations
  snowflake_account = "NXMEPIV-QGB61660"
  authenticator     = "SNOWFLAKE_JWT"
  user              = get_env("TF_VAR_snowflake_user", "")

  # Fallback role for a unit that is not listed in unit_roles. Keep it high only
  # while you are adding new units; every unit should have an entry below.
  role              = "ACCOUNTADMIN"

  # The role each unit signs in with (the folder names under this directory).
  # Your Snowflake user must have each role granted. These are the smallest
  # built-in roles that can do the job:
  #   SYSADMIN       creates databases, schemas, warehouses
  #   SECURITYADMIN  creates roles and users, grants privileges, owns network policies
  #   ACCOUNTADMIN   needed only for CREATE INTEGRATION (give a custom role that
  #                  privilege alone, then switch this to that role)
  unit_roles = {
    databases    = "SYSADMIN"
    warehouses   = "SYSADMIN"
    integrations = "ACCOUNTADMIN"
    security     = "SECURITYADMIN"
    users        = "SECURITYADMIN"
    rbac         = "SECURITYADMIN"
    monitoring   = "MONITOR_ADMIN" # created in the rbac unit; owns the monitoring objects
  }

  # The private key and passphrase are not set here. The Snowflake provider reads
  # SNOWFLAKE_PRIVATE_KEY and SNOWFLAKE_PRIVATE_KEY_PASSPHRASE from the
  # environment. See README.md.
}
