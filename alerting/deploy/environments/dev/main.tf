provider "google" {
  project = var.project
  region  = var.region
}

module "anomaly_alerting_dev" {
  source                = "../../template"
  project               = var.project
  environment           = "dev"
  docker_image          = var.docker_image
  region                = var.region
  service_account_email = var.service_account_email
  docker_registry       = var.docker_registry
  project_name          = var.anomaly_alerting_project_name
}
