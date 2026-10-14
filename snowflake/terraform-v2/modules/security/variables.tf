# ------------------------------------------------------------------------------
# Names are written UPPER CASE, exactly as they appear in Snowflake.
# A network policy does nothing until it is attached. This stack only DEFINES
# policies. Attach one to a user with `network_policy` in the users stack, which
# can only ever lock out that one user. Attaching a policy to the whole account
# is deliberately not done here: a wrong list would lock everyone out, including
# Terraform. Do that by hand, from a session you can recover.
# ------------------------------------------------------------------------------

variable "network_policies" {
  default     = {}
  description = <<-EOT
    Map of policy name => definition.

      allowed_ip_list  IPv4 addresses or CIDR ranges that may connect (required)
      blocked_ip_list  addresses carved out of the allowed ranges
      comment          free text

    0.0.0.0/0 is rejected in both lists: in the allowed list it makes the policy
    pointless, in the blocked list it blocks everyone.
  EOT

  type = map(object({
    allowed_ip_list = list(string)
    blocked_ip_list = optional(list(string), [])
    comment         = optional(string, "")
  }))

  validation {
    condition     = alltrue([for name in keys(var.network_policies) : can(regex("^[A-Z][A-Z0-9_$]*$", name))])
    error_message = "Policy names must be UPPER CASE Snowflake identifiers (letters, digits, _ and $, starting with a letter)."
  }

  validation {
    condition     = alltrue([for p in values(var.network_policies) : length(p.allowed_ip_list) > 0])
    error_message = "allowed_ip_list cannot be empty: a policy that allows nothing locks out whoever it is attached to."
  }

  validation {
    condition = alltrue(flatten([
      for p in values(var.network_policies) : [
        for ip in concat(p.allowed_ip_list, p.blocked_ip_list) :
        can(cidrhost(strcontains(ip, "/") ? ip : "${ip}/32", 0))
      ]
    ]))
    error_message = "Every entry must be an IPv4 address or CIDR range, such as 203.0.113.7 or 203.0.113.0/24."
  }

  validation {
    condition = alltrue(flatten([
      for p in values(var.network_policies) : [
        for ip in concat(p.allowed_ip_list, p.blocked_ip_list) : ip != "0.0.0.0/0"
      ]
    ]))
    error_message = "0.0.0.0/0 is not allowed in either list: it either disables the policy or blocks everyone."
  }
}
