# outputs.tf

output "ignored_privileges" {
  description = "Requested privileges this module does not apply (see the check at the end of main.tf)."
  value       = local.ignored_privileges
}
