provider "google" {
  project = "world-fishing-827"
}

module "anomaly_dataloader_dev" {
  source       = "../../template"
  project      = var.project
  environment  = "dev"
  docker_image = var.docker_image

  config_path = "../../../ci/executor/config_dev.yaml"
}