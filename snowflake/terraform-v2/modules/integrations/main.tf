locals {
  aws   = { for name, i in var.storage_integrations : name => i if contains(["S3", "S3GOV", "S3CHINA"], i.provider) }
  gcs   = { for name, i in var.storage_integrations : name => i if i.provider == "GCS" }
  azure = { for name, i in var.storage_integrations : name => i if i.provider == "AZURE" }
}

resource "snowflake_storage_integration_aws" "integration" {
  for_each = local.aws

  name                      = each.key
  enabled                   = each.value.enabled
  comment                   = each.value.comment == "" ? null : each.value.comment
  storage_provider          = each.value.provider
  storage_aws_role_arn      = each.value.storage_aws_role_arn
  storage_allowed_locations = each.value.storage_allowed_locations
  storage_blocked_locations = each.value.storage_blocked_locations
}

resource "snowflake_storage_integration_gcs" "integration" {
  for_each = local.gcs

  name                      = each.key
  enabled                   = each.value.enabled
  comment                   = each.value.comment == "" ? null : each.value.comment
  storage_allowed_locations = each.value.storage_allowed_locations
  storage_blocked_locations = each.value.storage_blocked_locations
}

resource "snowflake_storage_integration_azure" "integration" {
  for_each = local.azure

  name                      = each.key
  enabled                   = each.value.enabled
  comment                   = each.value.comment == "" ? null : each.value.comment
  azure_tenant_id           = each.value.azure_tenant_id
  storage_allowed_locations = each.value.storage_allowed_locations
  storage_blocked_locations = each.value.storage_blocked_locations
}
