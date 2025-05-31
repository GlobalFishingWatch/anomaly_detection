provider "google" {
  project = var.project
  region  = var.region
}

module "anomaly_dataloader_dev" {
  source                = "../../template"
  project               = var.project
  environment           = "dev"
  docker_image          = var.docker_image
  config_path           = "../../../ci/executor/config_dev.yaml"
  region                = var.region
  service_account_email = var.service_account_email
  docker_registry       = var.docker_registry
}