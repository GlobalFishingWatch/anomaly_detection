provider "google" {
  project = "world-fishing-827"
}

module "anomaly_alerting_prod" {
  source       = "../../template"
  project      = var.project
  environment  = "prod"
  docker_image = var.docker_image
}
