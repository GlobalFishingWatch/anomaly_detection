provider "google" {
  project = "world-fishing-827"
}

module "anomaly_alerting_dev" {
  source       = "../../template"
  project      = var.project
  environment  = "dev"
  docker_image = var.docker_image
}
