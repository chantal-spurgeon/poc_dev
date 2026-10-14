module "databases" {
  source = "../../../modules/databases"

  databases = var.databases
}
