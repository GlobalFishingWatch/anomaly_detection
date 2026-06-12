provider "google" {
  project = "world-fishing-827"
}


locals {

  project_name_dashed = format("qa-gfw-anomaly-detection-alerting-%s", var.environment)
  project_name_underscored = format("qa_gfw_anomaly_detection_alerting_%s", var.environment)
  project_name_print  = format("QA Anomaly detection alerting (%s)", var.environment)
  sa                  = "qa-anomaly-detection@world-fishing-827.iam.gserviceaccount.com"
  region              = "us-central1"
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

# Parent messages: one per (config_name, anomaly_date). Posted once at
# thread open and never edited. Updated in BQ only for status flip on
# close and for the debounce key (summary_counts_json).
resource "google_bigquery_table" "alerting_incidents" {
  dataset_id = "tech_anomaly_detection"
  table_id   = "t_${local.project_name_underscored}_incidents"
  project    = var.project

  time_partitioning {
    type  = "MONTH"
    field = "opened_at"
  }

  clustering = ["config_name", "anomaly_date"]

  schema = <<EOF
[
    {"name": "config_name", "type": "STRING"},
    {"name": "anomaly_date", "type": "DATE"},
    {"name": "slack_channel_id", "type": "STRING"},
    {"name": "slack_ts", "type": "STRING"},
    {"name": "opened_at", "type": "TIMESTAMP"},
    {"name": "closed_at", "type": "TIMESTAMP"},
    {"name": "status", "type": "STRING"},
    {"name": "client_msg_id", "type": "STRING"},
    {"name": "summary_counts_json", "type": "STRING"}
  ]
EOF

}

# Append-only event log of thread replies. One row per Slack reply posted.
# Each row captures the state announced by that reply; we never update
# rows. "Current state of dim X in thread Y" = ORDER BY posted_at DESC
# LIMIT 1 filtered by kind != 'summary'.
resource "google_bigquery_table" "alerting_incident_replies" {
  dataset_id = "tech_anomaly_detection"
  table_id   = "t_${local.project_name_underscored}_incident_replies"
  project    = var.project

  time_partitioning {
    type  = "MONTH"
    field = "posted_at"
  }

  clustering = ["incident_slack_ts", "dimension_split_value", "forecast_method"]

  schema = <<EOF
[
    {"name": "incident_slack_ts", "type": "STRING"},
    {"name": "config_name", "type": "STRING"},
    {"name": "dimension_split_value", "type": "STRING"},
    {"name": "forecast_method", "type": "STRING"},
    {"name": "slack_ts", "type": "STRING"},
    {"name": "slack_channel_id", "type": "STRING"},
    {"name": "kind", "type": "STRING"},
    {"name": "anomaly_type_lower_higher", "type": "STRING"},
    {"name": "previous_anomaly_type_lower_higher", "type": "STRING"},
    {"name": "anomaly_timestamp", "type": "TIMESTAMP"},
    {"name": "posted_at", "type": "TIMESTAMP"},
    {"name": "client_msg_id", "type": "STRING"}
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
      timeout         = "1800s" # 30m -- defence-in-depth so a slow run can't
                                #         orphan a parent message (Slack
                                #         parent posts but a SIGKILL mid-batch
                                #         skips the per-dim fire replies).
                                #         Steady-state runtime is well under
                                #         10m; bumping the cap is cheap
                                #         insurance.
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
              secret  = "projects/386173530526/secrets/QA_SLACK_BOT_USER_OAUTH_TOKEN"
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
            "--environment=${var.environment}",
            "--deduplication-index=${google_bigquery_table.deduplication_index.project}.${google_bigquery_table.deduplication_index.dataset_id}.${google_bigquery_table.deduplication_index.table_id}",
            "--incidents-table=${google_bigquery_table.alerting_incidents.project}.${google_bigquery_table.alerting_incidents.dataset_id}.${google_bigquery_table.alerting_incidents.table_id}",
            "--replies-table=${google_bigquery_table.alerting_incident_replies.project}.${google_bigquery_table.alerting_incident_replies.dataset_id}.${google_bigquery_table.alerting_incident_replies.table_id}",
          ]
        }]
      }
    }))

  }
}
