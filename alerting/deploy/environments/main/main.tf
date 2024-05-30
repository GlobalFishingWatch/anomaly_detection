provider "google" {
  project = "world-fishing-827"
}

module "anomaly_alerting_staging" {
  source       = "../../template"
  project      = var.project
  environment  = "staging"
  docker_image = var.docker_image
}
