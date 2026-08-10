# environment/snowflake_account_name/security/terragrunt.hcl

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}//snowflake/terragrunt"
}

inputs = {
  network_policies = {
    "corporate_vpn_only" = {
      allowed_ip_list = ["192.168.1.0/24", "10.0.0.0/8"]
      comment         = "Restricts login traffic exclusively to official corporate networks"
    }
  }
}

