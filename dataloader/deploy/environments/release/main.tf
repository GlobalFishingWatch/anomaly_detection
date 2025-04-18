provider "google" {
  project = "world-fishing-827"
}

module "anomaly_dataloader_prod" {
  source       = "../../template"
  project      = var.project
  environment  = "prod"
  docker_image = var.docker_image

  config_path = "../../../ci/executor/config_prod.yaml"
}
