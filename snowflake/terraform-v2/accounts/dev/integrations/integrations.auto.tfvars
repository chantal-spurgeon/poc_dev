# Storage integrations. This is the only file you edit to change them.
# Running Terraform in this folder cannot touch roles, grants, databases or users.
#
# PLACEHOLDERS: the role ARN and bucket names below are examples. Nothing here is a
# credential (an integration holds no key; the cloud side trusts Snowflake instead).
#
# After the first apply, read the outputs and finish the trust setup on the cloud side:
#   terraform output -json aws_trust_policy_inputs    (S3: IAM user ARN + external ID)
#   terraform output gcs_service_accounts              (GCS: service account to grant)
#
# Locations must end in "/", use the provider's scheme, and contain no wildcard.

storage_integrations = {

  AWS_S3_DATA_LAKE = {
    provider                  = "S3"
    comment                   = "AWS Storage Integration Staging"
    storage_aws_role_arn      = "arn:aws:iam::123456789012:role/snowflake-access-role"
    storage_allowed_locations = ["s3://your-jype-bucket/data/"]
  }

  GCS_DATA_LAKE = {
    provider                  = "GCS"
    comment                   = "Google Cloud Storage Integration Staging"
    storage_allowed_locations = ["gs://your-jype-gcp-bucket/raw/"]
  }
}
