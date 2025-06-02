terraform {
  backend "gcs" {
    bucket = "anomaly-detection-demo-461518-tfstate"
    prefix = "projects/anomaly_detection/alerting/release" # Not change for this project
  }
}