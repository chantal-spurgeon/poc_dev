# live/snowflake_account_name/security/terragrunt.hcl

# 1. Inherit the global backend, account settings, and Snowflake providers
include "root" {
  path   = find_in_parent_folders("root.hcl")
}

# 2. Point to your monolithic terraform source directory
terraform {
  source = "${get_repo_root()}//snowflake/terragrunt"
}

# 3. Inject the security-specific variables
inputs = {
  network_policies = {
#    "corporate_vpn_only" = {
#      allowed_ip_list = ["192.168.1.0/24", "10.0.0.0/8"]
#      blocked_ip_list = ["0.0.0.0/0"]
#      comment         = "Restricts login traffic exclusively to official corporate networks"
#    }
  },
}
