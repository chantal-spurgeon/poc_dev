output "managed_roles" {
  description = "Roles created by this stack, as name => name."
  value       = { for name, role in snowflake_account_role.role : name => role.name }
}
