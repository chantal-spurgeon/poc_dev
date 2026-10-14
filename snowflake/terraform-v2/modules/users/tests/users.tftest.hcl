# Offline tests for the users module (mock provider: no account, no credentials).
#
#   cd modules/users
#   terraform init -backend=false
#   terraform test
#
# The key below is a stand-in with the right shape, not a real key.
# Requires Terraform 1.7 or newer. Written without access to a Terraform binary,
# so the first run is also the first check of this file.

mock_provider "snowflake" {}

variables {
  users = {
    ALICE = {
      email        = "alice@example.com"
      login_name   = "alice@example.com"
      first_name   = "Alice"
      last_name    = "Example"
      default_role = "ANALYST"
    }

    SVC_LOADER = {
      type           = "SERVICE"
      email          = "data-team@example.com"
      default_role   = "LOADER"
      rsa_public_key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
      network_policy = "SERVICE_ONLY"
    }
  }
}

run "people_and_service_users_use_their_own_resources" {
  command = plan

  assert {
    condition     = keys(snowflake_user.person) == ["ALICE"]
    error_message = "ALICE should be a normal user."
  }

  assert {
    condition     = keys(snowflake_service_user.service) == ["SVC_LOADER"]
    error_message = "SVC_LOADER should be a service user."
  }

  assert {
    condition     = snowflake_user.person["ALICE"].default_secondary_roles_option == "NONE"
    error_message = "Secondary roles should default to NONE (least privilege)."
  }

  assert {
    condition     = snowflake_user.person["ALICE"].disabled == "false"
    error_message = "disabled is a string (\"false\") in provider 2.x."
  }
}

run "rejects_a_lower_case_name" {
  command = plan
  variables {
    users = { alice = { email = "a@example.com", default_role = "ANALYST" } }
  }
  expect_failures = [var.users]
}

run "rejects_an_admin_default_role" {
  command = plan
  variables {
    users = { ALICE = { email = "a@example.com", default_role = "ACCOUNTADMIN" } }
  }
  expect_failures = [var.users]
}

run "rejects_a_bad_email" {
  command = plan
  variables {
    users = { ALICE = { email = "not-an-email", default_role = "ANALYST" } }
  }
  expect_failures = [var.users]
}

run "rejects_a_bad_secondary_roles_value" {
  command = plan
  variables {
    users = { ALICE = { email = "a@example.com", default_role = "ANALYST", default_secondary_roles = "EVERYTHING" } }
  }
  expect_failures = [var.users]
}

run "rejects_a_service_user_without_a_key" {
  command = plan
  variables {
    users = { SVC = { type = "SERVICE", email = "a@example.com", default_role = "LOADER", network_policy = "SERVICE_ONLY" } }
  }
  expect_failures = [var.users]
}

run "rejects_a_service_user_without_a_network_policy" {
  command = plan
  variables {
    users = { SVC = { type = "SERVICE", email = "a@example.com", default_role = "LOADER", rsa_public_key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" } }
  }
  expect_failures = [var.users]
}

run "accepts_a_service_user_without_a_policy_when_the_rule_is_off" {
  command = plan
  variables {
    users = { SVC = { type = "SERVICE", email = "a@example.com", default_role = "LOADER", rsa_public_key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" } }
    require_network_policy_for_service_users = false
  }
}

run "rejects_a_key_pasted_with_its_header" {
  command = plan
  variables {
    users = { SVC = { type = "SERVICE", email = "a@example.com", default_role = "LOADER", network_policy = "SERVICE_ONLY", rsa_public_key = "-----BEGIN PUBLIC KEY-----" } }
  }
  expect_failures = [var.users]
}

run "rejects_a_key_that_is_too_short" {
  command = plan
  variables {
    users = { SVC = { type = "SERVICE", email = "a@example.com", default_role = "LOADER", network_policy = "SERVICE_ONLY", rsa_public_key = "AAAA" } }
  }
  expect_failures = [var.users]
}

run "rejects_a_name_on_a_service_user" {
  command = plan
  variables {
    users = { SVC = { type = "SERVICE", email = "a@example.com", first_name = "Svc", default_role = "LOADER", network_policy = "SERVICE_ONLY", rsa_public_key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" } }
  }
  expect_failures = [var.users]
}
