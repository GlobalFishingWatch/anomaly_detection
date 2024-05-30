provider "google" {
  project = "world-fishing-827"
}

module "anomaly_alerting_release" {
  source       = "../../template"
  project      = var.project
  environment  = "release"
  docker_image = var.docker_image
}
