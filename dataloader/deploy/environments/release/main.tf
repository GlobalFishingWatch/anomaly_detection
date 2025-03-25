provider "google" {
  project = "world-fishing-827"
}

module "anomaly_dataloader_release" {
  source       = "../../template"
  project      = var.project
  environment  = "release"
  docker_image = var.docker_image

  config_path = "../../../ci/executor/config_release.yaml"
}
