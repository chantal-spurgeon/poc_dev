# Roles, the role hierarchy, and every grant, in one file.
# This is the only file you edit to change RBAC. Running Terraform in this
# folder cannot touch databases, warehouses, users or integrations.
#
# Conventions: UPPER CASE names, schemas written DATABASE.SCHEMA, privileges in
# UPPER CASE. Users, databases, warehouses and integrations are created by their
# own stacks; here they are referred to by name only.

account_roles = {

  # SYSADMIN is a system role: it is not created here, only wired into the
  # hierarchy so it inherits the custom roles it must manage objects for.
  SYSADMIN = {
    inherits = ["PRODUCER"]
  }

  PRODUCER = {
    comment = "Role for 3RACHA"
    users   = ["BANGCHAN", "HAN"]

    warehouses   = { PRODUCER_WH = ["USAGE", "OPERATE", "MONITOR"] }
    integrations = { AWS_S3_DATA_LAKE = ["USAGE"] }
    databases    = { DB_STRAY_KIDS = ["USAGE"] }

    schemas = {
      # owner = true transfers OWNERSHIP of the schema to this role.
      "DB_STRAY_KIDS.CHANS_LAPTOP" = {
        owner = true
      }

      "DB_STRAY_KIDS.COMEBACKS" = {
        privileges = ["USAGE", "CREATE TABLE"]

        objects = {
          TABLES = {
            current = ["SELECT", "INSERT", "UPDATE", "DELETE"]
            future  = ["SELECT", "INSERT", "UPDATE", "DELETE"]
          }
          VIEWS = {
            current = ["SELECT"]
            future  = ["SELECT"]
          }
          PROCEDURES = {
            current = ["USAGE"]
            future  = ["USAGE"]
          }
          FUNCTIONS = {
            current = ["USAGE"]
            future  = ["USAGE"]
          }
          STAGES = {
            current = ["READ", "WRITE"]
            future  = ["READ", "WRITE"]
          }
          # TASKS is left out on purpose. The old file asked for OWNERSHIP on
          # tasks, which the old code silently dropped. Ownership is only
          # supported on schemas here; grant OPERATE / MONITOR if that is
          # what is needed:
          #   TASKS = { current = ["OPERATE", "MONITOR"], future = ["OPERATE", "MONITOR"] }
        }
      }
    }
  }

  # Replaces SECURITY_ADMIN_CUSTOM. It only needs to read security metadata, so
  # it gets Snowflake's read-only SECURITY_VIEWER database role instead of
  # inheriting SECURITYADMIN. It is not placed under SYSADMIN on purpose.
  SECURITY_MONITOR = {
    comment        = "Read-only visibility into account security metadata"
    users          = ["BANGCHAN"] # TODO: confirm this user should have it
    database_roles = ["SNOWFLAKE.SECURITY_VIEWER"]
  }
}
