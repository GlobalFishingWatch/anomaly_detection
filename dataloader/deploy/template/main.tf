provider "google" {
  project = var.project
  region  = var.region
}


locals {
  project_name_dashed = format("%s-%s", var.project_name, var.environment)
  sa                  = var.service_account_email
  region              = var.region
}

resource "google_bigquery_table" "actuals" {
  dataset_id = "tech_anomaly_detection"
  table_id   = "t_${var.environment}_actuals"
  project    = var.project

  time_partitioning {
    type  = "MONTH"
    field = "timestamp"
  }

  clustering = ["is_latest", "config_name", "dimension_split", "valid_to"]

  schema = <<EOF
[
    {"name": "key", "type": "BYTES"},
    {"name": "source_dataset", "type": "STRING"},
    {"name": "source_table", "type": "STRING"},
    {"name": "source_timestamp_column", "type": "STRING"},
    {"name": "source_timestamp_column_sql", "type": "STRING"},
    {"name": "source_forecast_column", "type": "STRING"},
    {"name": "source_forecast_column_sql", "type": "STRING"},
    {"name": "source_sql", "type": "STRING"},
    {"name": "source_sql_hash", "type": "STRING"},
    {"name": "period_length", "type": "STRING"},
    {"name": "timestamp", "type": "TIMESTAMP"},
    {"name": "value", "type": "FLOAT64"},
    {"name": "valid_from", "type": "TIMESTAMP"},
    {"name": "valid_to", "type": "TIMESTAMP"},
    {"name": "config_name", "type": "STRING"},
    {"name": "dimension_split", "type": "STRING"},
    {"name": "dimension_split_value", "type": "STRING"},
    {"name": "is_latest", "type": "BOOLEAN"}
  ]
EOF
}

resource "google_bigquery_table" "forecasts" {
  dataset_id = "tech_anomaly_detection"
  table_id   = "t_${var.environment}_forecasts"
  project    = var.project

  time_partitioning {
    type  = "MONTH"
    field = "timestamp"

  }

  clustering = ["is_latest", "config_name", "dimension_split", "valid_to"]

  schema = <<EOF
[
    {"name": "key", "type": "BYTES"},
    {"name": "source_dataset", "type": "STRING"},
    {"name": "source_table", "type": "STRING"},
    {"name": "source_timestamp_column", "type": "STRING"},
    {"name": "source_timestamp_column_sql", "type": "STRING"},
    {"name": "source_forecast_column", "type": "STRING"},
    {"name": "source_forecast_column_sql", "type": "STRING"},
    {"name": "source_sql", "type": "STRING"},
    {"name": "source_sql_hash", "type": "STRING"},
    {"name": "period_length", "type": "STRING"},
    {"name": "forecast_method", "type": "STRING"},
    {"name": "timestamp", "type": "TIMESTAMP"},
    {"name": "value", "type": "FLOAT64"},
    {"name": "valid_from", "type": "TIMESTAMP"},
    {"name": "valid_to", "type": "TIMESTAMP"},
    {"name": "config_name", "type": "STRING"},
    {"name": "dimension_split", "type": "STRING"},
    {"name": "dimension_split_value", "type": "STRING"},
    {"name": "is_latest", "type": "BOOLEAN"}
  ]
EOF

}


resource "google_cloud_run_v2_job" "job" {
  name     = local.project_name_dashed
  location = local.region
  project  = var.project

  deletion_protection = false

  template {
    task_count  = 1
    parallelism = 1
    template {
      service_account = local.sa
      timeout         = "1200s" # 60m
      max_retries     = 1

      containers {
        image = var.docker_image

        resources {
          limits = {
            cpu    = "8"
            memory = "4096Mi"
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
  for_each = toset(keys(yamldecode(file(var.config_path))["anomalies"]))

  name             = format("%s_scheduler_%s", local.project_name_dashed, each.key)
  schedule         = "20 10 * * *"
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
            "--anomaly_detection_config_name=${each.value}",
            "--forecast_timestamp_from='7 days'",
          ]
        }]
      }
    }))

  }
}
