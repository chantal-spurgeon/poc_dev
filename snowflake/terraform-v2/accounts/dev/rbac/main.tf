module "rbac" {
  source = "../../../modules/rbac"

  account_roles  = var.account_roles
  external_roles = var.external_roles
}
