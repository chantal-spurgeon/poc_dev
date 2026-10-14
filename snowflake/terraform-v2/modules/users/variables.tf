# ------------------------------------------------------------------------------
# Names are written UPPER CASE, exactly as they appear in Snowflake. The roles,
# warehouses and policies users refer to are created by their own stacks and are
# referred to here by name only.
#
# Passwords are not supported on purpose. A password would sit in the tfvars file
# or in the state. People sign in with single sign-on (or a key pair); service
# users use a key pair only.
# ------------------------------------------------------------------------------

variable "forbidden_default_roles" {
  type        = list(string)
  default     = ["ACCOUNTADMIN", "SECURITYADMIN", "USERADMIN"]
  description = <<-EOT
    Roles that cannot be a user's default role. A default role is active in every
    session, so an admin role there means every login, script and notebook runs
    with full power. People can switch to an admin role deliberately when needed.
  EOT
}

variable "require_network_policy_for_service_users" {
  type        = bool
  default     = true
  description = <<-EOT
    Every service user must name a network_policy. A service user's key is a
    long-lived credential; limiting where it can connect from is what makes a
    stolen key much less useful.
  EOT
}

variable "users" {
  default     = {}
  description = <<-EOT
    Map of user name => definition.

      type                     PERSON (default) or SERVICE
      login_name               what the user types; for people usually their email
      email                    required
      first_name, last_name    PERSON only
      default_role             required; not an admin role (see forbidden_default_roles)
      default_warehouse        a warehouse name
      default_namespace        DATABASE or DATABASE.SCHEMA
      default_secondary_roles  DEFAULT, NONE or ALL. ALL lets a session use every role
                               the user holds at once, which is convenient and widens
                               what any one session can do. NONE is least privilege.
      rsa_public_key           public key body on ONE line, no BEGIN/END lines.
                               Required for SERVICE users. rsa_public_key_2 is for
                               rotation: add the new key, switch the client, remove
                               the old one.
      network_policy           a policy defined in the security stack
      disabled                 true to lock the user without deleting them
      comment                  free text
  EOT

  type = map(object({
    type                    = optional(string, "PERSON")
    login_name              = optional(string)
    email                   = string
    first_name              = optional(string)
    last_name               = optional(string)
    default_role            = string
    default_warehouse       = optional(string)
    default_namespace       = optional(string)
    default_secondary_roles = optional(string, "NONE")
    rsa_public_key          = optional(string)
    rsa_public_key_2        = optional(string)
    network_policy          = optional(string)
    disabled                = optional(bool, false)
    comment                 = optional(string, "")
  }))

  validation {
    condition     = alltrue([for name in keys(var.users) : can(regex("^[A-Z][A-Z0-9_$]*$", name))])
    error_message = "User names must be UPPER CASE Snowflake identifiers (letters, digits, _ and $, starting with a letter)."
  }

  validation {
    condition     = alltrue([for u in values(var.users) : contains(["PERSON", "SERVICE"], u.type)])
    error_message = "type must be PERSON or SERVICE."
  }

  validation {
    condition     = alltrue([for u in values(var.users) : can(regex("^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$", u.email))])
    error_message = "email must look like name@example.com."
  }

  validation {
    condition = alltrue([
      for u in values(var.users) :
      can(regex("^[A-Z][A-Z0-9_$]*$", u.default_role)) && !contains(var.forbidden_default_roles, u.default_role)
    ])
    error_message = "default_role must be an UPPER CASE role name that is not an admin role (var.forbidden_default_roles: ACCOUNTADMIN, SECURITYADMIN, USERADMIN)."
  }

  validation {
    condition = alltrue([
      for u in values(var.users) :
      (u.default_warehouse == null ? true : can(regex("^[A-Z][A-Z0-9_$]*$", u.default_warehouse))) &&
      (u.network_policy == null ? true : can(regex("^[A-Z][A-Z0-9_$]*$", u.network_policy)))
    ])
    error_message = "default_warehouse and network_policy must be UPPER CASE Snowflake identifiers."
  }

  validation {
    condition = alltrue([
      for u in values(var.users) :
      u.default_namespace == null ? true : can(regex("^[A-Z][A-Z0-9_$]*([.][A-Z][A-Z0-9_$]*)?$", u.default_namespace))
    ])
    error_message = "default_namespace must be DATABASE or DATABASE.SCHEMA, in UPPER CASE."
  }

  validation {
    condition     = alltrue([for u in values(var.users) : contains(["DEFAULT", "NONE", "ALL"], u.default_secondary_roles)])
    error_message = "default_secondary_roles must be DEFAULT, NONE or ALL."
  }

  validation {
    condition = alltrue([
      for u in values(var.users) :
      u.type != "SERVICE" ? true : (u.rsa_public_key != null)
    ])
    error_message = "A SERVICE user must have an rsa_public_key: service users sign in with a key pair only."
  }

  validation {
    condition = alltrue(flatten([
      for u in values(var.users) : [
        for k in [for key in [u.rsa_public_key, u.rsa_public_key_2] : key if key != null] :
        can(regex("^[A-Za-z0-9+/]+={0,2}$", k)) && length(k) >= 350
      ]
    ]))
    error_message = "An RSA public key must be the base64 body on one line, without the BEGIN/END lines, and at least 2048 bits."
  }

  validation {
    condition = alltrue([
      for u in values(var.users) :
      u.type != "SERVICE" ? true : (u.first_name == null && u.last_name == null)
    ])
    error_message = "first_name and last_name belong to PERSON users only."
  }

  validation {
    condition = alltrue([
      for u in values(var.users) :
      (u.type != "SERVICE" || !var.require_network_policy_for_service_users) ? true : u.network_policy != null
    ])
    error_message = "Every SERVICE user must name a network_policy (var.require_network_policy_for_service_users). Define the policy in the security stack."
  }
}
