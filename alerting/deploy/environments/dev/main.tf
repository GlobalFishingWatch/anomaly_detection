provider "google" {
  project = var.project
  region  = var.region
}

module "anomaly_alerting_dev" {
  source                  = "../../template"
  project                 = var.project
  environment             = "dev"
  docker_image            = var.docker_image
  region                  = var.region
  service_account_email   = var.service_account_email
  docker_registry         = var.docker_registry
  project_name            = var.anomaly_alerting_project_name
  slack_bot_token_secret  = var.slack_bot_token_secret
  additional_users        = var.additional_users
}
