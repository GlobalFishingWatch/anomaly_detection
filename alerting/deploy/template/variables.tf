variable "project" {
  description = "GCP project ID for deployment"
  type        = string
}
variable "docker_image" {
  description = "Docker image to deploy"
  type        = string
}
variable "environment" {
  description = "Environment name (dev, staging, prod)"
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
}

variable "docker_registry" {
  description = "Docker registry URL"
  type        = string
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "anomaly-detection-alerting"
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

