# live/snowflake_account_name/integrations/terragrunt.hcl

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}//snowflake/terragrunt"
}

inputs = {
  storage_integrations = {
    "AWS_S3_DATA_LAKE8" = {
      provider                  = "S3"
      storage_aws_role_arn      = "arn:aws:iam::123456789012:role/snowflake-access-role"
      storage_allowed_locations = ["s3://your-jype-bucket/data/"]
      type                      = "EXTERNAL_STAGE"
      comment                   = "AWS Storage Integration Staging"
    }

    "GCS_DATA_LAKE8" = {
      provider                  = "GCS"
      storage_allowed_locations = ["gcs://your-jype-gcp-bucket/raw/"]
      type                      = "EXTERNAL_STAGE"
      comment                   = "Google Cloud Storage Integration Staging"

      # MAP HOMOGENIZATION FIX: Explicitly supply a null mapping key
      # to satisfy the strict map(any) attribute validation check
      storage_aws_role_arn      = null
    }
  }
}

