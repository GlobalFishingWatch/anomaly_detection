# Demo Project Configuration
project               = "anomaly-detection-demo-461518"
region                = "us-central1"
service_account_email = "anomaly-detection-dev@anomaly-detection-demo-461518.iam.gserviceaccount.com"
docker_registry       = "gcr.io/anomaly-detection-demo-461518"
anomaly_alerting_project_name = "demo-anomaly-detection-alerting"
anomaly_dataloader_project_name = "demo-anomaly-detection-dataloader"

# Docker images (will be built/pushed during deployment)
docker_image = "gcr.io/anomaly-detection-demo-461518/anomaly-detection:latest"

# Slack integration for demo (using fake token for testing)
slack_bot_token_secret = "projects/anomaly-detection-demo-461518/secrets/QA_SLACK_BOT_USER_OAUTH_TOKEN"

# Demo project users (add your email here)
additional_users = ["user:christianhomberg@gmail.com"]