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
  default     = "TF_INTEGRATION_ADMIN"
  description = "Role the provider uses. A custom role holding only CREATE INTEGRATION (created by hand once; see the README)."
}

# --- Definitions (integrations.auto.tfvars) ---------------------------------------------------
# The full type, defaults and validation rules live in modules/integrations/variables.tf.
# `any` here avoids declaring the same type twice; an invalid value is still
# rejected by the module before anything is planned.
variable "storage_integrations" {
  type    = any
  default = {}
}
