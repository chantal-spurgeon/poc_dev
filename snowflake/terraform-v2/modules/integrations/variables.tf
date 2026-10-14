# ------------------------------------------------------------------------------
# Names are written UPPER CASE, exactly as they appear in Snowflake.
# ------------------------------------------------------------------------------

variable "storage_integrations" {
  default     = {}
  description = <<-EOT
    Map of integration name => definition. A storage integration lets Snowflake
    read (and write) a cloud bucket without any key in Snowflake: the cloud side
    trusts a Snowflake identity instead.

      provider                   S3, S3GOV, S3CHINA, GCS or AZURE
      storage_allowed_locations  where Snowflake may read and write. Written with the
                                 provider's scheme (s3://, gcs://, azure://), and each
                                 location ends in "/" so that s3://bucket/data/ cannot
                                 also match s3://bucket/data-private/. No wildcards.
      storage_blocked_locations  carve-outs inside the allowed locations
      storage_aws_role_arn       S3 types only: the IAM role Snowflake assumes
      azure_tenant_id            AZURE only
      enabled                    true by default
      comment                    free text

    After the first apply, read the `aws_trust_policy_inputs`, `gcs_service_accounts`
    or `azure_consent` output and finish the cloud-side trust setup.
  EOT

  type = map(object({
    provider                  = string
    storage_allowed_locations = list(string)
    storage_blocked_locations = optional(list(string), [])
    storage_aws_role_arn      = optional(string)
    azure_tenant_id           = optional(string)
    enabled                   = optional(bool, true)
    comment                   = optional(string, "")
  }))

  validation {
    condition     = alltrue([for name in keys(var.storage_integrations) : can(regex("^[A-Z][A-Z0-9_$]*$", name))])
    error_message = "Integration names must be UPPER CASE Snowflake identifiers (letters, digits, _ and $, starting with a letter)."
  }

  validation {
    condition     = alltrue([for i in values(var.storage_integrations) : contains(["S3", "S3GOV", "S3CHINA", "GCS", "AZURE"], i.provider)])
    error_message = "provider must be one of S3, S3GOV, S3CHINA, GCS, AZURE."
  }

  validation {
    condition     = alltrue([for i in values(var.storage_integrations) : length(i.storage_allowed_locations) > 0])
    error_message = "storage_allowed_locations cannot be empty: an integration with no allowed location is useless, and the alternative would be everything."
  }

  validation {
    condition = alltrue(flatten([
      for i in values(var.storage_integrations) : [
        for loc in concat(i.storage_allowed_locations, i.storage_blocked_locations) :
        !strcontains(loc, "*")
      ]
    ]))
    error_message = "Wildcard locations (*) are not allowed. Name the bucket paths Snowflake needs."
  }

  validation {
    condition = alltrue(flatten([
      for i in values(var.storage_integrations) : [
        for loc in concat(i.storage_allowed_locations, i.storage_blocked_locations) :
        startswith(loc, lookup({ S3 = "s3://", S3GOV = "s3gov://", S3CHINA = "s3china://", GCS = "gcs://", AZURE = "azure://" }, i.provider, "invalid://"))
      ]
    ]))
    error_message = "Every location must use its provider's scheme: s3:// (S3), s3gov:// (S3GOV), s3china:// (S3CHINA), gcs:// (GCS) or azure:// (AZURE)."
  }

  validation {
    condition = alltrue(flatten([
      for i in values(var.storage_integrations) : [
        for loc in i.storage_allowed_locations : endswith(loc, "/")
      ]
    ]))
    error_message = "Every allowed location must end in \"/\". Without it, s3://bucket/data also matches s3://bucket/data-private."
  }

  validation {
    condition = alltrue([
      for i in values(var.storage_integrations) :
      !contains(["S3", "S3GOV", "S3CHINA"], i.provider) ? true : (
        i.storage_aws_role_arn != null && can(regex("^arn:aws(-us-gov|-cn)?:iam::[0-9]{12}:role/.+$", i.storage_aws_role_arn))
      )
    ])
    error_message = "S3 integrations need storage_aws_role_arn, written arn:aws:iam::<12-digit account id>:role/<name>."
  }

  validation {
    condition = alltrue([
      for i in values(var.storage_integrations) :
      i.provider != "AZURE" ? true : (
        i.azure_tenant_id != null && can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", i.azure_tenant_id))
      )
    ])
    error_message = "AZURE integrations need azure_tenant_id, written as a GUID."
  }

  validation {
    condition = alltrue([
      for i in values(var.storage_integrations) :
      (contains(["S3", "S3GOV", "S3CHINA"], i.provider) || i.storage_aws_role_arn == null) &&
      (i.provider == "AZURE" || i.azure_tenant_id == null)
    ])
    error_message = "storage_aws_role_arn only belongs on S3 integrations and azure_tenant_id only on AZURE ones."
  }
}
