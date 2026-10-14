output "warehouses" {
  description = "Names of the warehouses this stack manages. Use these exact spellings in the rbac stack."
  value       = sort([for name, w in snowflake_warehouse.warehouse : w.name])
}
