provider "google" {
  project = "world-fishing-827"
}


locals {

  project_name_dashed = format("qa-gfw-anomaly-detection-dataloder-%s", var.environment)
  project_name_print  = format("QA Anomaly detection data loader (%s)", var.environment)
  sa                  = "qa-anomaly-detection@world-fishing-827.iam.gserviceaccount.com"
  region              = "us-central1"
}

resource "google_bigquery_table" "actuals" {
  dataset_id = "tech_anomaly_detection"
  table_id   = "t_${var.environment}_actuals"
  project    = var.project
  
  time_partitioning {
    type = "DAY"
    field = "timestamp"
  }

  clustering = [ "config_name", "dimension_split" ]

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
    {"name": "value", "type": "FLOAT"},
    {"name": "valid_from", "type": "TIMESTAMP"},
    {"name": "valid_to", "type": "TIMESTAMP"},
    {"name": "config_name", "type": "STRING"},
    {"name": "dimension_split", "type": "STRING"},
    {"name": "dimension_split_value", "type": "STRING"}
  ]
EOF
}

resource "google_bigquery_table" "forecasts" {
  dataset_id = "tech_anomaly_detection"
  table_id   = "t_${var.environment}_forecasts"
  project    = var.project
  
  time_partitioning {
    type = "DAY"
    field = "timestamp"
  }

  clustering = [ "config_name", "dimension_split" ]

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
    {"name": "value", "type": "FLOAT"},
    {"name": "valid_from", "type": "TIMESTAMP"},
    {"name": "valid_to", "type": "TIMESTAMP"},
    {"name": "config_name", "type": "STRING"},
    {"name": "dimension_split", "type": "STRING"},
    {"name": "dimension_split_value", "type": "STRING"}
  ]
EOF

}

resource "google_bigquery_table" "actuals_forecasts" {
  dataset_id = "tech_anomaly_detection"
  table_id   = "v_${var.environment}_deltas"
  project    = var.project

  view {
    query = templatefile("${path.module}/res/sql/v_anomaly_detection_deltas.sql", {
      ENVIRONMENT = var.environment
    })
    use_legacy_sql = false
  }
}
resource "google_storage_bucket_object" "csv_files" {
  for_each = fileset("${var.cwd}/res/csv", "**/*")

  bucket = "tech_anomaly_detection"
  source = "${var.cwd}/res/csv/${each.value}"
  name   = "${var.environment}/res/csv/${each.value}"
}

resource "google_bigquery_table" "csv" {
  for_each = fileset("${var.cwd}/res/csv", "**/*")

  dataset_id = "tech_anomaly_detection"
  table_id   = "t_${var.environment}_${replace(each.value, ".csv", "")}"
  project    = var.project

  external_data_configuration {
    source_format = "CSV"
    autodetect    = true
    source_uris  = ["gs://tech_anomaly_detection/${var.environment}/res/csv/${each.value}"]
  }
  
  depends_on = [google_storage_bucket_object.csv_files]
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
      timeout         = "3600s" # 60m
      max_retries     = 3

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
  schedule         = "0 9 * *  1"
  time_zone        = "Europe/Madrid"
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

  }
}
