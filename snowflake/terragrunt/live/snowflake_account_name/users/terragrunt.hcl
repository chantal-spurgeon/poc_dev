# live/snowflake_account_name/users/terragrunt.hcl

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}//snowflake/terragrunt"
}

inputs = {
  users = {
    "bangchan8" = {
      login_name              = "bang.chan8@jype.com"
      email                   = "bang.chan@jype.com"
      first_name              = "Christopher"
      last_name               = "Bahng"
      default_role            = "PRODUCER8"
      default_secondary_roles = ["\"ALL\""]
      default_warehouse       = "PRODUCER8_WH"
      default_namespace       = "DB_STRAY_KIDS8.CHANS_LAPTOP"
      user_type               = "PERSON"
      comment                 = "Leader of Stray Kids"

      # Explicitly supply null placeholders
      # for unique service profile attributes
      rsa_public_key          = null
      rsa_public_key_2        = null
    }

    "stray_kids_admin8" = {
      login_name              = "stray_kids_admin8"
      email                   = "devops-notify@jype.com"
      default_role            = "PRODUCER8"
      default_secondary_roles = ["\"ALL\""]
      default_warehouse       = "PRODUCER8_WH"
      default_namespace       = "DB_STRAY_KIDS8.CHANS_LAPTOP"
      user_type               = "SERVICE"
      comment                 = "Stray Kids Service Account"
      rsa_public_key          = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArSLIeQeToXiKeza8EAE+O46/4qAK6WnNE1gqbkQbwF9LWi/6uoTxNpY/DGNbM2Qbzr1RQO7CZb3CsklGh39ry2HOTXnRAQRXiiVQgNlson9twYU9mgpVjWO9j1kK1BQdLwp//QuYoywU+Mrm32xACiUoX1TX8hz54PcjAX92RRQ+IrCTY42THTBycUu95thf3uXKSHlmy6xzdLXdFeU2Yebf73OpmBeCfHDDGYNiDOLgZnay/JfVQAKQwuwSHWCxAcgt7etZ9QJqfAhMOT4q4AB7f4C5vgAEUq4xhhPELdCa42vT6KC7WnbLGvu6Govv1sL0yK54Wk+ePflx2MXW1wIDAQAB"

      # Explicitly supply null placeholders
      # for unique human profile attributes
      rsa_public_key_2        = null
      first_name              = null
      last_name               = null
    }
  }
}

