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
variable "config_path" {
  description = "Path to configuration file"
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
  description = "Project name for dataloader resource naming"
  type        = string
  default     = "anomaly-detection-dataloader"
}

variable "additional_users" {
  description = "Additional users to grant Cloud Run access (e.g., ['user:email@domain.com'])"
  type        = list(string)
  default     = []
}