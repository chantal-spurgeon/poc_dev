locals {
  people   = { for name, u in var.users : name => u if u.type == "PERSON" }
  services = { for name, u in var.users : name => u if u.type == "SERVICE" }
}

# In provider 2.x a user's `disabled` is the string "true" / "false".
# No password is ever set here (see variables.tf).
resource "snowflake_user" "person" {
  for_each = local.people

  name                           = each.key
  login_name                     = each.value.login_name
  email                          = each.value.email
  first_name                     = each.value.first_name
  last_name                      = each.value.last_name
  default_role                   = each.value.default_role
  default_warehouse              = each.value.default_warehouse
  default_namespace              = each.value.default_namespace
  default_secondary_roles_option = each.value.default_secondary_roles
  rsa_public_key                 = each.value.rsa_public_key
  rsa_public_key_2               = each.value.rsa_public_key_2
  network_policy                 = each.value.network_policy
  disabled                       = tostring(each.value.disabled)
  comment                        = each.value.comment == "" ? null : each.value.comment
}

resource "snowflake_service_user" "service" {
  for_each = local.services

  name                           = each.key
  login_name                     = each.value.login_name
  email                          = each.value.email
  default_role                   = each.value.default_role
  default_warehouse              = each.value.default_warehouse
  default_namespace              = each.value.default_namespace
  default_secondary_roles_option = each.value.default_secondary_roles
  rsa_public_key                 = each.value.rsa_public_key
  rsa_public_key_2               = each.value.rsa_public_key_2
  network_policy                 = each.value.network_policy
  disabled                       = tostring(each.value.disabled)
  comment                        = each.value.comment == "" ? null : each.value.comment
}
