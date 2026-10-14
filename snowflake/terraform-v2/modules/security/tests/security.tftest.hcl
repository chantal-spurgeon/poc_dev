# Offline tests for the security module (mock provider: no account, no credentials).
#
#   cd modules/security
#   terraform init -backend=false
#   terraform test
#
# Requires Terraform 1.7 or newer. Written without access to a Terraform binary,
# so the first run is also the first check of this file.

mock_provider "snowflake" {}

variables {
  network_policies = {
    OFFICE_ONLY = {
      allowed_ip_list = ["203.0.113.0/24", "198.51.100.7"]
      blocked_ip_list = ["203.0.113.99"]
      comment         = "test"
    }
  }
}

run "a_valid_policy_becomes_a_resource" {
  command = plan

  assert {
    condition     = keys(snowflake_network_policy.policy) == ["OFFICE_ONLY"]
    error_message = "OFFICE_ONLY should be created."
  }

  assert {
    condition     = length(snowflake_network_policy.policy["OFFICE_ONLY"].allowed_ip_list) == 2
    error_message = "Both allowed entries should pass through."
  }
}

run "rejects_a_lower_case_name" {
  command         = plan
  variables       { network_policies = { office = { allowed_ip_list = ["203.0.113.0/24"] } } }
  expect_failures = [var.network_policies]
}

run "rejects_an_empty_allowed_list" {
  command         = plan
  variables       { network_policies = { OFFICE = { allowed_ip_list = [] } } }
  expect_failures = [var.network_policies]
}

run "rejects_allow_everything" {
  command         = plan
  variables       { network_policies = { OFFICE = { allowed_ip_list = ["0.0.0.0/0"] } } }
  expect_failures = [var.network_policies]
}

run "rejects_block_everything" {
  command         = plan
  variables       { network_policies = { OFFICE = { allowed_ip_list = ["203.0.113.0/24"], blocked_ip_list = ["0.0.0.0/0"] } } }
  expect_failures = [var.network_policies]
}

run "rejects_an_address_that_is_not_an_ip" {
  command         = plan
  variables       { network_policies = { OFFICE = { allowed_ip_list = ["office.example.com"] } } }
  expect_failures = [var.network_policies]
}

run "rejects_an_octet_above_255" {
  command         = plan
  variables       { network_policies = { OFFICE = { allowed_ip_list = ["300.1.1.1"] } } }
  expect_failures = [var.network_policies]
}

run "rejects_a_prefix_above_32" {
  command         = plan
  variables       { network_policies = { OFFICE = { allowed_ip_list = ["10.0.0.0/33"] } } }
  expect_failures = [var.network_policies]
}
