# Development Environment Setup

This guide helps you set up your own GCP project for anomaly detection development and testing.

## Prerequisites

- GCP account with billing enabled
- gcloud CLI installed and configured
- Docker installed locally

## Quick Setup (5 minutes)

### 1. Create GCP Project

```bash
# Create project (replace with your preferred ID)
export PROJECT_ID="anomaly-detection-dev-$(date +%s)"
gcloud projects create $PROJECT_ID --name="Anomaly Detection Dev"
gcloud config set project $PROJECT_ID

# Enable billing in GCP Console if needed
echo "Enable billing for project $PROJECT_ID at:"
echo "https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID"
```

### 2. Enable APIs & Setup Service Account

```bash
# Enable APIs
gcloud services enable \
  bigquery.googleapis.com \
  cloudbuild.googleapis.com \
  cloudrun.googleapis.com \
  cloudscheduler.googleapis.com

# Create service account
gcloud iam service-accounts create anomaly-detection \
  --description="Anomaly Detection Service Account" \
  --display-name="Anomaly Detection"

# Grant permissions
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:anomaly-detection@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/bigquery.dataEditor"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:anomaly-detection@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/bigquery.jobUser"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:anomaly-detection@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/run.invoker"
```

### 3. Setup Environment

```bash
# Set environment variables
export GCP_PROJECT_ID=$PROJECT_ID
export BQ_DATASET="anomaly_detection_demo"
export DBT_ENVIRONMENT="dev"

# Make permanent
echo "export GCP_PROJECT_ID=$PROJECT_ID" >> ~/.bashrc
echo "export BQ_DATASET=anomaly_detection_demo" >> ~/.bashrc
echo "export DBT_ENVIRONMENT=dev" >> ~/.bashrc
source ~/.bashrc
```

### 4. Create BigQuery Dataset

```bash
bq mk --location=US --dataset $PROJECT_ID:anomaly_detection_demo
```

## Test Your Setup

### Option A: Run Quickstart Demo

```bash
cd quickstart
./run_demo.sh
```

### Option B: Manual Test

```bash
cd quickstart
export GCP_PROJECT_ID="your-project-id"
export BQ_DATASET="anomaly_detection_demo"
docker-compose up --build
```

## Development Workflow

### Local Development

```bash
# Test dataloader locally
cd dataloader/ci/executor
export GCP_PROJECT_ID="your-project-id"
export BQ_DATASET="anomaly_detection_demo"
docker-compose up

# Test alerting locally (optional - requires Slack setup)
cd alerting/ci/executor
docker-compose up
```

### DBT Development

```bash
cd dbt
source setenv.sh  # Sets DBT_ENVIRONMENT based on git branch
dbt seed          # Deploy lookup tables
```

### Infrastructure Deployment

```bash
# Copy and customize Terraform variables
cp terraform.tfvars.example terraform.tfvars

# Edit terraform.tfvars:
# project = "your-project-id"
# service_account_email = "anomaly-detection@your-project-id.iam.gserviceaccount.com"
# docker_registry = "gcr.io/your-project-id"

# Deploy to dev environment
cd dataloader/deploy/environments/dev
terraform init
terraform apply -var-file="../../../../terraform.tfvars"
```

## Cost Estimation

**Free Tier Resources:**
- BigQuery: 1TB queries/month, 10GB storage
- Cloud Run: 2M requests/month
- Cloud Scheduler: 3 jobs/month

**Expected Monthly Costs:**
- Development usage: $5-15/month
- Light production: $20-50/month
- Heavy usage: $100+/month

## Troubleshooting

### Common Issues

**"Permission denied" errors**
- Ensure billing is enabled
- Check service account permissions
- Verify you're authenticated: `gcloud auth application-default login`

**Docker build failures**
- Ensure Docker is running
- Check internet connectivity
- Try rebuilding: `docker-compose build --no-cache`

**BigQuery access issues**
- Verify dataset exists: `bq ls $PROJECT_ID:anomaly_detection_demo`
- Check project ID is correct: `gcloud config get-value project`

### Useful Commands

```bash
# Check current setup
echo "Project: $(gcloud config get-value project)"
echo "Account: $(gcloud config get-value account)"
echo "Environment: $GCP_PROJECT_ID / $BQ_DATASET"

# List BigQuery datasets
bq ls

# Check Docker containers
docker ps

# View recent logs
docker-compose logs
```

## Next Steps

1. **Run the quickstart demo** to verify everything works
2. **Explore the data** in BigQuery Console
3. **Modify configs** to try different algorithms or data sources  
4. **Set up alerting** by configuring Slack integration
5. **Deploy to Cloud Run** using the Terraform infrastructure

## Support

- Check `quickstart/README.md` for demo-specific help
- Review `PROJECT_SETUP.md` for full production setup
- Look at existing configs in `dataloader/ci/executor/config_dev.yaml` for examples