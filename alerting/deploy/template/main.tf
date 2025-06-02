provider "google" {
  project = var.project
  region  = var.region
}


locals {
  project_name_dashed = format("%s-%s", var.project_name, var.environment)
  project_name_underscored = format("%s_%s", replace(var.project_name, "-", "_"), var.environment)
  sa                  = var.service_account_email
  region              = var.region
}

resource "google_bigquery_table" "deduplication_index" {
  dataset_id = "tech_anomaly_detection"
  table_id   = "t_${local.project_name_underscored}_deduplication-index"
  project    = var.project

  time_partitioning {
    type  = "MONTH"
    field = "processed_at"

  }

  clustering = ["event_hash"]

  schema = <<EOF
[
    {"name": "event_hash", "type": "STRING"},
    {"name": "processed_at", "type": "TIMESTAMP"},
    {"name": "rendered_message", "type": "STRING"}
  ]
EOF

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
          name = "SLACK_BOT_TOKEN"
          value_source {
            secret_key_ref {
              secret  = var.slack_bot_token_secret
              version = "latest"
            }
          }
        }

        env {
          name = "LOG_LEVEL"
          value = "info"
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
    members = concat([
      format("serviceAccount:%s", local.sa),
    ], var.additional_users)
  }
  binding {
    role = "roles/run.developer"
    members = concat([
      format("serviceAccount:%s", local.sa),
    ], var.additional_users)
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
  region           = var.region
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
            "--environment=${var.environment}",
            "--deduplication-index=${google_bigquery_table.deduplication_index.project}.${google_bigquery_table.deduplication_index.dataset_id}.${google_bigquery_table.deduplication_index.table_id}",
          ]
        }]
      }
    }))

  }
}
