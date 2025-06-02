terraform {
  backend "gcs" {
    bucket = "anomaly-detection-demo-461518-tfstate"
    prefix = "projects/anomaly_detection/alerting/cloudbuild" # Not change for this project
  }
}