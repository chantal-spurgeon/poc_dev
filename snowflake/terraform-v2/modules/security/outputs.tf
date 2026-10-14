output "network_policies" {
  description = "Names of the network policies this stack manages. Use these exact spellings as `network_policy` in the users stack."
  value       = sort([for name, p in snowflake_network_policy.policy : p.name])
}
