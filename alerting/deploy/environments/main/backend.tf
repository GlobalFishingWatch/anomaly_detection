terraform {
  backend "gcs" {
    bucket = "skytruth-pelagos-production-tfstate-us-central1"
    prefix = "projects/anomaly_detection/alerting/main" # Not change for this project
  }
}