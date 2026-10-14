# --- Connection (not secret; set in connection.auto.tfvars) ---------------------
variable "snowflake_organization_name" {
  type        = string
  description = "Snowflake organization name."
}

variable "snowflake_account_name" {
  type        = string
  description = "Snowflake account name (not the full locator)."
}

variable "snowflake_user" {
  type        = string
  description = "Dedicated service user for this stack (TYPE = SERVICE, key-pair only)."
}

variable "snowflake_role" {
  type        = string
  default     = "SECURITYADMIN"
  description = "Role the provider uses. Users need USERADMIN, or SECURITYADMIN to attach a network policy to them."
}

# --- Definitions (users.auto.tfvars) ---------------------------------------------------
# The full type, defaults and validation rules live in modules/users/variables.tf.
# `any` here avoids declaring the same type twice; an invalid value is still
# rejected by the module before anything is planned.
variable "users" {
  type    = any
  default = {}
}
