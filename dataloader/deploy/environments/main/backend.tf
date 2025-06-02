terraform {
  backend "gcs" {
    bucket = "anomaly-detection-demo-461518-tfstate"
    prefix = "projects/anomaly_detection/dataloader/main" # Not change for this project
  }
}