# environment/root.hcl

locals {
  # Load the shared account configurations
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))

  snowflake_account = local.account_vars.locals.snowflake_account
  authenticator     = local.account_vars.locals.authenticator
  user              = local.account_vars.locals.user

  # Each unit signs in with its own role. unit_roles (account.hcl) maps a unit's
  # folder name to a role; a unit not listed there falls back to "role".
  # get_terragrunt_dir() is the folder of the unit being run, so this is evaluated
  # per unit even though it is written once, here.
  unit = basename(get_terragrunt_dir())
  role = lookup(local.account_vars.locals.unit_roles, local.unit, local.account_vars.locals.role)
}

inputs = {
  snowflake_account = local.snowflake_account
  snowflake_user    = local.user
  snowflake_role    = local.role
}

# The private key and its passphrase are deliberately NOT written here. The
# Snowflake provider reads them from the environment when they are not set in
# the provider block:
#
#   SNOWFLAKE_PRIVATE_KEY              the key itself (contents of the .p8 file)
#   SNOWFLAKE_PRIVATE_KEY_PASSPHRASE   its passphrase, if the key is encrypted
#
# Writing them into this generated file would leave them in plain text in
# .terragrunt-cache/ for every unit.
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite"
  contents  = <<EOF
provider "snowflake" {
  account       = "${local.snowflake_account}"
  user          = "${local.user}"
  role          = "${local.role}"
  authenticator = "${local.authenticator}"

  experimental_features_enabled = ["PROVIDER_CONFIGURATION_ACCOUNT_FALLBACK"]
  preview_features_enabled      = ["snowflake_storage_integration_resource", "snowflake_table_resource", "snowflake_procedure_sql_resource"]
}
EOF
}

# DESTROY GUARD. `terragrunt destroy` (and `run --all destroy`) refuses to start
# unless ALLOW_DESTROY=yes is set in the environment. This is the first layer;
# lifecycle { prevent_destroy = true } in main.tf is the second and stops a destroy
# or replacement of the protected resources even when this hook is bypassed.
# Whether a hook in this parent file is merged with the child's own terraform
# block (which sets source) should be confirmed with the test in the README.
terraform {
  before_hook "block_destroy" {
    commands = ["destroy"]
    execute = [
      "bash", "-c",
      "if [ \"$ALLOW_DESTROY\" != \"yes\" ]; then echo 'BLOCKED: destroy needs ALLOW_DESTROY=yes (see README, Protections)' >&2; exit 1; fi"
    ]
  }
}

# STATE. Until this block is enabled, each unit keeps its state as a local file
# inside .terragrunt-cache/. Deleting that folder (or cloning the repo on another
# machine) loses the state and orphans everything Terraform created.
#
# To enable: create the bucket, replace the placeholders, remove the leading "#".
# Note the single $ in key: this block is read by Terragrunt, not copied into a
# generated file, so ${...} is evaluated here. ($${...} is only for text inside
# the "generate" heredoc above that Terraform itself must evaluate.) With the
# key below, every unit gets its own state file, for example
#   databases/terraform.tfstate, rbac/terraform.tfstate
#
# use_lockfile (S3 native locking) needs Terraform 1.11 or newer; versions.tf requires
# 1.15, so it is available here.
#
#remote_state {
#  backend = "s3"
#  generate = {
#    path      = "backend.tf"
#    if_exists = "overwrite"
#  }
#  config = {
#    bucket       = "my-snowflake-tf-state-bucket"
#    key          = "${path_relative_to_include()}/terraform.tfstate"
#    region       = "us-east-1"
#    encrypt      = true
#    use_lockfile = true
#  }
#}
