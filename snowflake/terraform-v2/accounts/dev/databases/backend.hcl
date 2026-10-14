# Passed to `terraform init -backend-config=backend.hcl`. Nothing secret belongs
# here; AWS credentials come from your environment or an assumed role.
#
# One state per stack, so the key includes the account and the stack name.
bucket       = "REPLACE-ME-terraform-state"
key          = "snowflake/dev/databases/terraform.tfstate"
region       = "us-east-1"
encrypt      = true
use_lockfile = true # S3-native locking (Terraform >= 1.11), no DynamoDB table needed
