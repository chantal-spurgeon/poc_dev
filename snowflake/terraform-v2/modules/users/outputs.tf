output "users" {
  description = "Names of the people this stack manages. Use these exact spellings in the rbac stack."
  value       = sort([for name, u in snowflake_user.person : u.name])
}

output "service_users" {
  description = "Names of the service users this stack manages."
  value       = sort([for name, u in snowflake_service_user.service : u.name])
}
