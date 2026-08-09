# terragrunt/variables.tf

variable "snowflake_organization" {
  type        = string
  description = "The Snowflake organization name"
  default     = null # Allows child modules to ignore if not explicitly needed
}

variable "snowflake_account" {
  type        = string
  description = "Target account name where objects will be built"
}

# Matching variables loaded via TF_VAR_ environment prefixes
variable "snowflake_user" {
  type        = string
  description = "The Snowflake user running the Terraform execution"
}

variable "snowflake_role" {
  type    = string
  default = "ACCOUNTADMIN"
}

variable "snowflake_authenticator" {
  type        = string
  default     = "SNOWFLAKE_JWT"
  description = "Authentication method (e.g., SNOWFLAKE_JWT)"
}

variable "snowflake_password" {
  type      = string
  default   = null
  sensitive = true
}

variable "snowflake_private_key" {
  type        = string
  sensitive   = true
  default     = null # Optional fallback depending on authentication strategy
  description = "The raw unencrypted or encrypted private key string structure"
}

variable "snowflake_private_key_path" {
  type        = string
  sensitive   = true
  default     = null
  description = "The raw unencrypted or encrypted private key string structure"
}

variable "snowflake_private_key_passphrase" {
  type        = string
  sensitive   = true
  default     = null
  description = "The optional passphrase to decrypt the private key file"
}


# ==============================================================================
# STRUCTURAL STATE MODULE MAPS (All decoupled with clean empty defaults)
# ==============================================================================

# The Map structure for the Databases input file
variable "databases" {
  type        = map(any)
  description = "Map of databases and nested schemas"
  default     = {} # <-- ADDED: Crucial to let other stacks deploy without breaking
}

# The Map structure for the Warehouses input file
variable "warehouses" {
  type        = map(any)
  description = "Map containing configuration parameters for Snowflake virtual warehouses"
  default     = {}
}

# Network Policies Map
variable "network_policies" {
  type        = map(any)
  description = "Map of network policies and their allowed/blocked IP ranges"
  default     = {}
}

# Storage Integrations Map
variable "storage_integrations" {
  type        = map(any)
  description = "Map of AWS, GCS, or Azure storage integrations"
  default     = {}
}

# Custom Security Roles Map
variable "account_roles" {
  type        = map(any)
  description = "Comprehensive map of roles, user memberships, and privileges"
  default     = {}
}

# Users Map
variable "users" {
  type        = map(any)
  description = "Map containing human and service account profiles"
  default     = {}
}



