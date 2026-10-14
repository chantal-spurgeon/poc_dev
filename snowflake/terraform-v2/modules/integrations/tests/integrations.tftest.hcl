# Offline tests for the integrations module (mock provider: no account, no credentials).
#
#   cd modules/integrations
#   terraform init -backend=false
#   terraform test
#
# Requires Terraform 1.7 or newer. Written without access to a Terraform binary,
# so the first run is also the first check of this file.

mock_provider "snowflake" {}

variables {
  storage_integrations = {
    LAKE_S3 = {
      provider                  = "S3"
      storage_aws_role_arn      = "arn:aws:iam::123456789012:role/snowflake-access"
      storage_allowed_locations = ["s3://bucket-one/data/"]
      storage_blocked_locations = ["s3://bucket-one/data/private/"]
    }
    LAKE_GCS = {
      provider                  = "GCS"
      storage_allowed_locations = ["gcs://bucket-two/raw/"]
    }
    LAKE_AZ = {
      provider                  = "AZURE"
      azure_tenant_id           = "11111111-2222-3333-4444-555555555555"
      storage_allowed_locations = ["azure://account.blob.core.windows.net/container/"]
    }
  }
}

run "each_provider_uses_its_own_resource" {
  command = plan

  assert {
    condition     = keys(snowflake_storage_integration_aws.integration) == ["LAKE_S3"]
    error_message = "LAKE_S3 should be an AWS integration."
  }

  assert {
    condition     = keys(snowflake_storage_integration_gcs.integration) == ["LAKE_GCS"]
    error_message = "LAKE_GCS should be a GCS integration."
  }

  assert {
    condition     = keys(snowflake_storage_integration_azure.integration) == ["LAKE_AZ"]
    error_message = "LAKE_AZ should be an Azure integration."
  }

  assert {
    condition     = snowflake_storage_integration_aws.integration["LAKE_S3"].storage_provider == "S3"
    error_message = "The AWS resource needs storage_provider set from the provider field."
  }
}

run "rejects_a_lower_case_name" {
  command = plan
  variables {
    storage_integrations = { lake = { provider = "GCS", storage_allowed_locations = ["gcs://b/x/"] } }
  }
  expect_failures = [var.storage_integrations]
}

run "rejects_an_unknown_provider" {
  command = plan
  variables {
    storage_integrations = { LAKE = { provider = "DROPBOX", storage_allowed_locations = ["gcs://b/x/"] } }
  }
  expect_failures = [var.storage_integrations]
}

run "rejects_a_wildcard_location" {
  command = plan
  variables {
    storage_integrations = { LAKE = { provider = "GCS", storage_allowed_locations = ["gcs://*"] } }
  }
  expect_failures = [var.storage_integrations]
}

run "rejects_a_location_without_a_trailing_slash" {
  command = plan
  variables {
    storage_integrations = { LAKE = { provider = "GCS", storage_allowed_locations = ["gcs://bucket/data"] } }
  }
  expect_failures = [var.storage_integrations]
}

run "rejects_a_location_with_the_wrong_scheme" {
  command = plan
  variables {
    storage_integrations = { LAKE = { provider = "GCS", storage_allowed_locations = ["s3://bucket/data/"] } }
  }
  expect_failures = [var.storage_integrations]
}

run "rejects_an_empty_allowed_list" {
  command = plan
  variables {
    storage_integrations = { LAKE = { provider = "GCS", storage_allowed_locations = [] } }
  }
  expect_failures = [var.storage_integrations]
}

run "rejects_s3_without_a_role_arn" {
  command = plan
  variables {
    storage_integrations = { LAKE = { provider = "S3", storage_allowed_locations = ["s3://b/x/"] } }
  }
  expect_failures = [var.storage_integrations]
}

run "rejects_a_malformed_role_arn" {
  command = plan
  variables {
    storage_integrations = { LAKE = { provider = "S3", storage_aws_role_arn = "snowflake-access", storage_allowed_locations = ["s3://b/x/"] } }
  }
  expect_failures = [var.storage_integrations]
}

run "rejects_azure_without_a_tenant_id" {
  command = plan
  variables {
    storage_integrations = { LAKE = { provider = "AZURE", storage_allowed_locations = ["azure://a.blob.core.windows.net/c/"] } }
  }
  expect_failures = [var.storage_integrations]
}

run "rejects_a_role_arn_on_a_gcs_integration" {
  command = plan
  variables {
    storage_integrations = { LAKE = { provider = "GCS", storage_aws_role_arn = "arn:aws:iam::123456789012:role/x", storage_allowed_locations = ["gcs://b/x/"] } }
  }
  expect_failures = [var.storage_integrations]
}
