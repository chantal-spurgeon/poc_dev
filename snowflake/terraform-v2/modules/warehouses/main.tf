# In provider 2.x a warehouse's auto_resume is the string "true" / "false"
# (initially_suspended is a real boolean).
resource "snowflake_warehouse" "warehouse" {
  for_each = var.warehouses

  name                         = each.key
  comment                      = each.value.comment == "" ? null : each.value.comment
  warehouse_size               = each.value.warehouse_size
  warehouse_type               = each.value.warehouse_type
  auto_suspend                 = each.value.auto_suspend
  auto_resume                  = tostring(each.value.auto_resume)
  initially_suspended          = each.value.initially_suspended
  min_cluster_count            = each.value.min_cluster_count
  max_cluster_count            = each.value.max_cluster_count
  scaling_policy               = each.value.scaling_policy
  statement_timeout_in_seconds = each.value.statement_timeout_in_seconds
}
