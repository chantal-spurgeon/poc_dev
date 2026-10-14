output "databases" {
  description = "Names of the databases and replicas this stack manages."
  value = sort(concat(
    [for name, db in snowflake_database.database : db.name],
    [for name, db in snowflake_secondary_database.replica : db.name]
  ))
}

output "schemas" {
  description = "DATABASE.SCHEMA names this stack manages. Use these exact spellings in the rbac stack."
  value       = sort(keys(snowflake_schema.schema))
}
