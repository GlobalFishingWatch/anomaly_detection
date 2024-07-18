provider "google" {
  project = "world-fishing-827"
}


locals {

  project_name_dashed = format("qa-gfw-anomaly-detection-alerting-%s", var.environment)
  project_name_print  = format("QA Anomaly detection alerting (%s)", var.environment)
  sa                  = "qa-anomaly-detection@world-fishing-827.iam.gserviceaccount.com"
  region              = "us-central1"
}

resource "google_cloud_run_v2_job" "job" {
  name     = local.project_name_dashed
  location = local.region
  project  = var.project
  template {
    task_count  = 1
    parallelism = 1
    template {
      service_account = local.sa
      timeout         = "600s" # 10m
      max_retries     = 3

      containers {
        image = var.docker_image

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }

        env {
          name = "SLACK_WEBHOOK_URL"
          value_source {
            secret_key_ref {
              secret  = "projects/386173530526/secrets/QA_WEBHOOK_URL"
              version = "latest"
            }
          }
        }
      }
    }
  }

  labels = {
    environment      = var.environment
    resource_creator = "data"
    project          = "anomaly_detection"
    version          = ""
    step             = ""
    stage            = "prototype"
  }
}

data "google_iam_policy" "cloud_run_invoker" {
  binding {
    role = "roles/run.invoker"
    members = [
      format("serviceAccount:%s", local.sa),
      "user:christian.homberg@globalfishingwatch.org",
      "user:raul@globalfishingwatch.org",
    ]
  }
  binding {
    role = "roles/run.developer"
    members = [
      format("serviceAccount:%s", local.sa),
      "user:christian.homberg@globalfishingwatch.org",
      "user:raul@globalfishingwatch.org",
    ]
  }
}

resource "google_cloud_run_v2_job_iam_policy" "policy" {
  project     = google_cloud_run_v2_job.job.project
  location    = google_cloud_run_v2_job.job.location
  name        = google_cloud_run_v2_job.job.name
  policy_data = data.google_iam_policy.cloud_run_invoker.policy_data
}

resource "google_cloud_scheduler_job" "job" {
  name             = format("%s_scheduler", local.project_name_dashed)
  schedule         = "0 * * * *"
  attempt_deadline = "320s"
  region           = "us-central1"
  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"

    uri = format("https://%s-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/%s/jobs/%s:run", local.region, var.project, local.project_name_dashed)
    headers = {
      "User-Agent" = "Google-Cloud-Scheduler"
    }
    oauth_token {
      service_account_email = local.sa
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }

    body = base64encode(jsonencode({
      overrides = {
        containerOverrides = [{
          args = [
            "--environment=${var.environment}"
          ]
        }]
      }
    }))

  }
}

resource "google_firestore_index" "alerting_deduplication_index" {
  collection = format("%s_deduplication-index", local.project_name_dashed)
  query_scope = "COLLECTION_RECURSIVE"
  api_scope = "DATASTORE_MODE_API"
  fields {
    field_path = "processed_at"
    order      = "ASCENDING"
  }

  fields {
    field_path = "event_hash"
    order      = "ASCENDING"
  }
}
