# Network policies. This is the only file you edit to change them.
# Running Terraform in this folder cannot touch roles, grants, databases or users.
#
# This stack only DEFINES policies. A policy takes effect when it is attached:
#   * to one user, with `network_policy` in the users stack (safe: it can only lock
#     out that user), or
#   * to the whole account, by hand. That is deliberately not done here: a wrong list
#     would lock out everyone, including Terraform.
#
# IPv4 addresses or CIDR ranges only. 0.0.0.0/0 is rejected.

network_policies = {

  # Used by the service users in the users stack.
  #
  # PLACEHOLDER: 203.0.113.0/24 is a documentation range (RFC 5737) that no real
  # client uses. Replace it with the addresses your scripts and CI really connect
  # from BEFORE a real service user depends on it; a wrong list locks that user out.
  SERVICE_USERS_ONLY = {
    comment         = "Where service users may connect from"
    allowed_ip_list = ["203.0.113.0/24"]
  }

  # corporate_vpn_only, from the old file, kept as a pattern:
  # CORPORATE_VPN_ONLY = {
  #   comment         = "Restricts login traffic exclusively to official corporate networks"
  #   allowed_ip_list = ["192.168.1.0/24", "10.0.0.0/8"]
  # }
}
