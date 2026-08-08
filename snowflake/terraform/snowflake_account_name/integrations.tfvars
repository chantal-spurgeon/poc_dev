storage_integrations = {
  "aws_s3_data_lake" = {
    type                      = "EXTERNAL_STAGE"
    provider                  = "S3"
    storage_allowed_locations = ["s3://stray-kids/demos/", "s3://stray-kids/releases/"]
    storage_aws_role_arn      = "arn:aws:iam::123456789012:role/snowflake-access-role"
    comment                   = "Secure access cloud object storage buckets"
  },

}
