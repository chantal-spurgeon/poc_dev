# Databases and schemas. This is the only file you edit to change them.
# Running Terraform in this folder cannot touch roles, grants, warehouses or users.
#
# Conventions: UPPER CASE names, written exactly as Snowflake has them. Roles and
# privileges on these objects are granted in the rbac stack, by the same names.
#
# Databases and schemas are never dropped by Terraform (prevent_destroy). See
# "Retiring a database or schema" in the README.

databases = {

  DB_STRAY_KIDS = {
    comment                  = "Production chaos."
    is_transient             = true
    data_retention_time_days = 1

    schemas = {
      # Transient like the database unless is_transient says otherwise.
      CHANS_LAPTOP = {
        comment        = "The area we all want to see but never will"
        managed_access = false
      }

      COMEBACKS = {
        comment = "The final product we love"
        # true = only the schema owner (or a role with MANAGE GRANTS) can grant
        # privileges on objects in it. Recommended for shared schemas.
        managed_access = true
      }
    }
  }

  # A read-only replica of a database in another account (disaster recovery).
  # Replicas copy their schemas from the primary, so none are listed here.
  #
  # DB_STRAY_KIDS_REPLICA = {
  #   comment    = "Disaster recovery copy."
  #   replica_of = "MY_ORG.PRIMARY_ACCOUNT.DB_STRAY_KIDS"
  # }
}
