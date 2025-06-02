# GFW Production Configuration
project               = "world-fishing-827"
region                = "us-central1"
service_account_email = "qa-anomaly-detection@world-fishing-827.iam.gserviceaccount.com"
docker_registry       = "gcr.io/world-fishing-827"
anomaly_alerting_project_name = "qa-gfw-anomaly-detection-alerting"  # Preserve existing GFW naming
anomaly_dataloader_project_name = "qa-gfw-anomaly-detection-dataloader"  # Preserve existing GFW naming
additional_users = ["user:christian.homberg@globalfishingwatch.org", "user:raul@globalfishingwatch.org"]  # GFW team access