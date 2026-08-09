terraform {
  required_version = ">= 1.5.0"
  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = "~> 0.94.0"
    }
  }


#  backend "s3" {
#    bucket         = "corporate-terraform-states"
#    key            = "snowflake/accounts/dev_account/terraform.tfstate"
#    region         = "us-east-1"
#    dynamodb_table = "terraform-locks"
#  }
}

# ==============================================================================
variable "snowflake_organization" {
  type = string
}

variable "snowflake_account" {
  type = string
}

variable "snowflake_user" {
  type = string
}

variable "snowflake_authenticator" {
  type    = string
}

variable "snowflake_private_key" {
  type      = string
  sensitive = true
}

variable "snowflake_private_key_path" {
  type      = string
  sensitive = true
}

variable "snowflake_private_key_passphrase" {
  type      = string
  sensitive = true
  default   = null
}

variable "databases" {
  default = {}
}

variable "warehouses" {
  default = {}
}

variable "account_roles" {
  default = {}
}

variable "users" {
  default = {}
}

variable "network_policies" {
  default = {}
}

variable "storage_integrations" {
  default = {}
}