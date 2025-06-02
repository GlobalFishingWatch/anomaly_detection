terraform {
  backend "gcs" {
    bucket = "skytruth-pelagos-production-tfstate-us-central1"
    prefix = "projects/anomaly_detection/dataloader/cloudbuild" # Not change for this project
  }
}