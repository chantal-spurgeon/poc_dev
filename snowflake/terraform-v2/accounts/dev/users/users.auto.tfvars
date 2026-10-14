# Users and service users. This is the only file you edit to change them.
# Running Terraform in this folder cannot touch roles, grants, databases or warehouses.
#
# Conventions: UPPER CASE names, written exactly as Snowflake has them. The roles,
# warehouses and policies named here are created by their own stacks. Roles are granted
# to these users in the rbac stack (`users = [...]` on a role), by the same names.
#
# There are no passwords anywhere: people sign in with single sign-on, and service users
# with a key pair. A public key is not a secret, so it may sit in this file.

users = {

  # --- people ---------------------------------------------------------------------
  BANGCHAN = {
    login_name   = "bang.chan@jype.com"
    email        = "bang.chan@jype.com"
    first_name   = "Christopher"
    last_name    = "Bahng"
    comment      = "Leader of Stray Kids"
    default_role = "PRODUCER"
    # ALL lets a session use every role the user holds at once. It matches the old file;
    # NONE (the default) is least privilege and makes the user pick a role per session.
    default_secondary_roles = "ALL"
    default_warehouse       = "PRODUCER_WH"
    default_namespace       = "DB_STRAY_KIDS.CHANS_LAPTOP"
  }

  HAN = {
    login_name              = "han.jisung@jype.com"
    email                   = "han.jisung@jype.com"
    first_name              = "Jisung"
    last_name               = "Han"
    comment                 = "Leader of Stray Kids"
    default_role            = "PRODUCER"
    default_secondary_roles = "ALL"
    default_warehouse       = "PRODUCER_WH"
    default_namespace       = "DB_STRAY_KIDS.CHANS_LAPTOP"
  }

  # --- service accounts: key pair only, and a network policy -----------------------
  STRAY_KIDS_ADMIN = {
    type              = "SERVICE"
    login_name        = "stray_kids_admin"
    email             = "devops-notify@jype.com"
    comment           = "Stray Kids Service Account"
    default_role      = "PRODUCER"
    default_warehouse = "PRODUCER_WH"
    default_namespace = "DB_STRAY_KIDS.CHANS_LAPTOP"
    network_policy    = "SERVICE_USERS_ONLY" # defined in the security stack
    rsa_public_key    = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArSLIeQeToXiKeza8EAE+O46/4qAK6WnNE1gqbkQbwF9LWi/6uoTxNpY/DGNbM2Qbzr1RQO7CZb3CsklGh39ry2HOTXnRAQRXiiVQgNlson9twYU9mgpVjWO9j1kK1BQdLwp//QuYoywU+Mrm32xACiUoX1TX8hz54PcjAX92RRQ+IrCTY42THTBycUu95thf3uXKSHlmy6xzdLXdFeU2Yebf73OpmBeCfHDDGYNiDOLgZnay/JfVQAKQwuwSHWCxAcgt7etZ9QJqfAhMOT4q4AB7f4C5vgAEUq4xhhPELdCa42vT6KC7WnbLGvu6Govv1sL0yK54Wk+ePflx2MXW1wIDAQAB"
  }
}
