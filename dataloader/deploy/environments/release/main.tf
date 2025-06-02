provider "google" {
  project = var.project
  region  = var.region
}

module "anomaly_dataloader_prod" {
  source                = "../../template"
  project               = var.project
  environment           = "prod"
  docker_image          = var.docker_image
  config_path           = "../../../ci/executor/config_prod.yaml"
  region                = var.region
  service_account_email = var.service_account_email
  docker_registry       = var.docker_registry
  project_name          = var.anomaly_dataloader_project_name
  additional_users      = var.additional_users
}
