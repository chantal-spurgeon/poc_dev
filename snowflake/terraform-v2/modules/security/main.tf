resource "snowflake_network_policy" "policy" {
  for_each = var.network_policies

  name            = each.key
  comment         = each.value.comment == "" ? null : each.value.comment
  allowed_ip_list = each.value.allowed_ip_list
  blocked_ip_list = each.value.blocked_ip_list
}
