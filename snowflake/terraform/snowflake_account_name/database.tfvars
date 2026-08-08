databases = {
  "db_stray_kids" = {
    comment                  = "Production chaos."
    data_retention_time_days = 1
    is_transient            = true

    schemas = {
      "chans_laptop" = {
        comment        = "The area we all want to see but never will"
        is_transient   = true
        managed_access = false
      },
      "comebacks" = {
        comment        = "The final product we love"
        is_transient   = true
        managed_access = true
      }
    }
  },

  # A replicated secondary database (Failover/DR copy)
  "db_stray_kids_replica" = {
    comment                  = "Disaster Recovery Archive."
    data_retention_time_days = 1
    is_transient            = true
    is_replica            = true
    primary_database_path = "MY_ORG_NAME.PRIMARY_PROD_ACCOUNT.ANALYTICS_DB"

    # Schemas are read-only on replicas and managed by replication sync,
    # so we leave the schemas map blank for this entry.
    schemas = {}
  },

}