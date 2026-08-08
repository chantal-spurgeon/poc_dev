users = {
  # Standard Human Profile
  "bangchan" = {
    login_name        = "bang.chan@jype.com"
    email             = "bang.chan@jype.com"
    first_name        = "Christopher"
    last_name         = "Bahng"
    default_role      = "PRODUCER"
    default_warehouse = "PRODUCER_WH"
    default_database  = "DB_STRAY_KIDS"
    default_schema    = "CHANS_LAPTOP"
    user_type         = "PERSON" # or SERVICE for application accounts
    comment           = "Leader of Stray Kids"
  },

  # Service Account Profile
  "stray_kids_admin" = {
    login_name        = "stray_kids_admin"
    email             = "devops-notify@jype.com"
    default_role      = "PRODUCER"
    default_warehouse = "PRODUCER_WH"
    default_database  = "DB_STRAY_KIDS"
    default_schema    = "CHANS_LAPTOP"
    user_type         = "SERVICE" # Explicitly locks down authentication mechanisms in Snowflake
    comment           = "Stray Kids Service Account"
    rsa_public_key    = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAv1A..."
  },

}

