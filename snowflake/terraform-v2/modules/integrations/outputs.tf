output "integrations" {
  description = "Names of the integrations this stack manages. Use these exact spellings in the rbac stack."
  value = sort(concat(
    [for name, i in snowflake_storage_integration_aws.integration : i.name],
    [for name, i in snowflake_storage_integration_gcs.integration : i.name],
    [for name, i in snowflake_storage_integration_azure.integration : i.name]
  ))
}

# The values the cloud side needs to trust Snowflake. The provider only exposes
# them inside describe_output. The external ID is the guard in the IAM trust
# policy against a confused-deputy attack, so the output is marked sensitive.
output "aws_trust_policy_inputs" {
  description = "Per S3 integration: the Snowflake IAM user ARN and external ID for the role's trust policy."
  sensitive   = true
  value = {
    for name, i in snowflake_storage_integration_aws.integration : name => {
      iam_user_arn = try(i.describe_output[0].iam_user_arn, null)
      external_id  = try(i.describe_output[0].external_id, null)
    }
  }
}

output "gcs_service_accounts" {
  description = "Per GCS integration: the Snowflake service account to grant access to the bucket."
  value       = { for name, i in snowflake_storage_integration_gcs.integration : name => try(i.describe_output[0].service_account, null) }
}

output "azure_consent" {
  description = "Per Azure integration: the consent URL to open and the app name to grant access to."
  value = {
    for name, i in snowflake_storage_integration_azure.integration : name => {
      consent_url           = try(i.describe_output[0].consent_url, null)
      multi_tenant_app_name = try(i.describe_output[0].multi_tenant_app_name, null)
    }
  }
}
