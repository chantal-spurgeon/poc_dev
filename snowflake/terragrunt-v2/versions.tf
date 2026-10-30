# terragrunt-v2/versions.tf

terraform {
  # 1.14 and older are end of life. 1.15 is the oldest line still supported; it also
  # has everything this code uses (optional() defaults, check blocks, S3 use_lockfile).
  required_version = ">= 1.15.0"

  required_providers {
    snowflake = {
      source = "snowflakedb/snowflake"
      # Latest stable at the time of writing (released 2026-10-29). "~> 2.22.1" accepts
      # 2.22.x patch releases and nothing newer. To move to a new minor release, read
      # its migration guide, change this line, and run `terragrunt init -upgrade`.
      version = "~> 2.22.1"
    }
  }
}
