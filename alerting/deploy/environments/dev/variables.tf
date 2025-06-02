variable "project" {
  description = "GCP project ID for development environment"
  type        = string
  default     = "your-dev-project-id"  # Update this with your dev project
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
  default     = "anomaly-detection-dev@your-dev-project-id.iam.gserviceaccount.com"  # Update this
}

variable "docker_registry" {
  description = "Docker registry URL"
  type        = string
  default     = "gcr.io/your-dev-project-id"  # Update this
}

variable "anomaly_alerting_project_name" {
  description = "Project name for anomaly alerting resource naming (e.g., 'qa-gfw-anomaly-detection-alerting' for GFW)"
  type        = string
}

variable "slack_bot_token_secret" {
  description = "Full path to Slack bot token secret in Secret Manager"
  type        = string
}

variable "additional_users" {
  description = "Additional users to grant access to Cloud Run jobs"
  type        = list(string)
  default     = []
}

