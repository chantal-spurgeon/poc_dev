module "security" {
  source = "../../../modules/security"

  network_policies = var.network_policies
}
