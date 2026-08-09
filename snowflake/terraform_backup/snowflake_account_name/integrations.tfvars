storage_integrations = {
  "AWS_S3_DATA_LAKE" = {
    provider                  = "S3"
    storage_aws_role_arn      = "arn:aws:iam::123456789012:role/snowflake-access-role"
    storage_allowed_locations = ["s3://your-jype-bucket/data/"]
    type                      = "EXTERNAL_STAGE"  # Add if missing here too
    comment                   = "AWS Storage Integration Staging"
  }

  "GCS_DATA_LAKE" = {
    provider                  = "GCS"
    storage_allowed_locations = ["gcs://your-jype-gcp-bucket/raw/"]

    # FIX: Explicitly supply the missing keys to satisfy the module type check
    type                      = "EXTERNAL_STAGE"
    comment                   = "Google Cloud Storage Integration Staging"
  }
}

