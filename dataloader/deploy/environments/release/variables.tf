variable "project" {
  description = "GCP project ID for release environment"
  type        = string
  default     = "your-release-project-id"  # Update this with your release project
}

variable "docker_image" {
  description = "Docker image to deploy"
  type        = string
}

variable "region" {
  description = "GCP region for deployment"
  type        = string
  default     = "us-central1"
}

variable "service_account_email" {
  description = "Service account email for Cloud Run"
  type        = string
  default     = "anomaly-detection-release@your-release-project-id.iam.gserviceaccount.com"  # Update this
}

variable "docker_registry" {
  description = "Docker registry URL"
  type        = string
  default     = "gcr.io/your-release-project-id"  # Update this
}

variable "anomaly_dataloader_project_name" {
  description = "Project name for anomaly dataloader resource naming (e.g., 'qa-gfw-anomaly-detection-dataloader' for GFW)"
  type        = string
}

variable "additional_users" {
  description = "Additional users to grant Cloud Run access (e.g., ['user:email@domain.com'])"
  type        = list(string)
  default     = []
}


