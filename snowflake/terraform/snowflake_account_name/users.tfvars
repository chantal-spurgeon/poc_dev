users = {
  # Standard Human Profile
  "bangchan" = {
    login_name        = "bang.chan@jype.com"
    email             = "bang.chan@jype.com"
    first_name        = "Christopher"
    last_name         = "Bahng"
    default_role      = "PRODUCER"
    default_secondary_roles = ["\"ALL\""]
    default_warehouse = "PRODUCER_WH"
    default_namespace  = "DB_STRAY_KIDS.CHANS_LAPTOP"
    user_type         = "PERSON" # or SERVICE for application accounts
    comment           = "Leader of Stray Kids"
  },
  "han" = {
    login_name        = "han.jisung@jype.com"
    email             = "han.jisung@jype.com"
    first_name        = "Jisung"
    last_name         = "Han"
    default_role      = "PRODUCER"
    default_secondary_roles = ["\"ALL\""]
    default_warehouse = "PRODUCER_WH"
    default_namespace  = "DB_STRAY_KIDS.CHANS_LAPTOP"
    user_type         = "PERSON" # or SERVICE for application accounts
    comment           = "Leader of Stray Kids"
  },

  # Service Account Profile
  "stray_kids_admin" = {
    login_name        = "stray_kids_admin"
    email             = "devops-notify@jype.com"
    default_role      = "PRODUCER"
    default_secondary_roles = ["\"ALL\""]
    default_warehouse = "PRODUCER_WH"
    default_namespace = "DB_STRAY_KIDS.CHANS_LAPTOP"
    user_type         = "SERVICE" # Explicitly locks down authentication mechanisms in Snowflake
    comment           = "Stray Kids Service Account"
    rsa_public_key    = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArSLIeQeToXiKeza8EAE+O46/4qAK6WnNE1gqbkQbwF9LWi/6uoTxNpY/DGNbM2Qbzr1RQO7CZb3CsklGh39ry2HOTXnRAQRXiiVQgNlson9twYU9mgpVjWO9j1kK1BQdLwp//QuYoywU+Mrm32xACiUoX1TX8hz54PcjAX92RRQ+IrCTY42THTBycUu95thf3uXKSHlmy6xzdLXdFeU2Yebf73OpmBeCfHDDGYNiDOLgZnay/JfVQAKQwuwSHWCxAcgt7etZ9QJqfAhMOT4q4AB7f4C5vgAEUq4xhhPELdCa42vT6KC7WnbLGvu6Govv1sL0yK54Wk+ePflx2MXW1wIDAQAB"
  },

}

