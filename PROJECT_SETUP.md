# GCP Project Setup Guide

This guide explains how to set up a new GCP project for anomaly detection development and testing.

## Prerequisites

- GCP account with project creation permissions
- Terraform installed
- gcloud CLI configured
- Docker installed for local development

## Step 1: Create GCP Project

1. Create a new GCP project:
   ```bash
   gcloud projects create your-dev-project-id --name="Anomaly Detection Dev"
   ```

2. Enable required APIs:
   ```bash
   gcloud services enable bigquery.googleapis.com \
     cloudbuild.googleapis.com \
     cloudrun.googleapis.com \
     cloudscheduler.googleapis.com \
     secretmanager.googleapis.com \
     --project=your-dev-project-id
   ```

## Step 2: Create Service Account

1. Create service account:
   ```bash
   gcloud iam service-accounts create anomaly-detection-dev \
     --description="Anomaly Detection Development Service Account" \
     --display-name="Anomaly Detection Dev" \
     --project=your-dev-project-id
   ```

2. Grant necessary permissions:
   ```bash
   # BigQuery permissions
   gcloud projects add-iam-policy-binding your-dev-project-id \
     --member="serviceAccount:anomaly-detection-dev@your-dev-project-id.iam.gserviceaccount.com" \
     --role="roles/bigquery.dataEditor"
   
   gcloud projects add-iam-policy-binding your-dev-project-id \
     --member="serviceAccount:anomaly-detection-dev@your-dev-project-id.iam.gserviceaccount.com" \
     --role="roles/bigquery.jobUser"
   
   # Cloud Run permissions
   gcloud projects add-iam-policy-binding your-dev-project-id \
     --member="serviceAccount:anomaly-detection-dev@your-dev-project-id.iam.gserviceaccount.com" \
     --role="roles/run.invoker"
   
   # Secret Manager permissions (for Slack token)
   gcloud projects add-iam-policy-binding your-dev-project-id \
     --member="serviceAccount:anomaly-detection-dev@your-dev-project-id.iam.gserviceaccount.com" \
     --role="roles/secretmanager.secretAccessor"
   ```

## Step 3: Create BigQuery Dataset

```bash
bq mk --location=US --dataset your-dev-project-id:tech_anomaly_detection
```

## Step 4: Configure Environment Variables

Create environment-specific configuration files:

### For Terraform Deployment
Copy and customize the terraform variables:
```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
project               = "your-dev-project-id"
region                = "us-central1"  
service_account_email = "anomaly-detection-dev@your-dev-project-id.iam.gserviceaccount.com"
docker_registry       = "gcr.io/your-dev-project-id"
```

### For Application Runtime
Set environment variables for the application:
```bash
export GCP_PROJECT_ID="your-dev-project-id"
export BQ_DATASET="tech_anomaly_detection"
```

## Step 5: Setup Slack Integration (Optional)

1. Create a Slack app and get bot token
2. Store in Secret Manager:
   ```bash
   echo "your-slack-bot-token" | gcloud secrets create QA_SLACK_BOT_USER_OAUTH_TOKEN \
     --data-file=- --project=your-dev-project-id
   ```

## Step 6: Deploy Infrastructure

### Deploy Cloud Build Triggers
```bash
cd cloudbuild
terraform init
terraform apply
```

### Deploy Environment-Specific Infrastructure
```bash
cd dataloader/deploy/environments/dev
terraform init
terraform apply -var-file="../../../../terraform.tfvars"

cd ../../../../alerting/deploy/environments/dev  
terraform init
terraform apply -var-file="../../../../terraform.tfvars"
```

## Step 7: Configure DBT

1. Set up DBT environment:
   ```bash
   cd dbt
   source setenv.sh  # This will set DBT_ENVIRONMENT based on git branch
   ```

2. Update seed files for your environment by copying existing ones:
   ```bash
   cp seeds/thresholds_dev.csv seeds/thresholds_yourenv.csv
   cp seeds/config_descriptions_dev.csv seeds/config_descriptions_yourenv.csv
   ```

3. Deploy DBT seeds:
   ```bash
   dbt seed
   ```

## Step 8: Test the Setup

1. Test dataloader locally:
   ```bash
   cd dataloader/ci/executor
   docker-compose up
   ```

2. Test alerting locally:
   ```bash
   cd alerting/ci/executor
   docker-compose up
   ```

## Environment Configuration

The system supports multiple environment configurations:

### Development Environment Variables
```bash
export GCP_PROJECT_ID="your-dev-project-id"
export BQ_DATASET="tech_anomaly_detection"
export DBT_ENVIRONMENT="dev"
```

### Production Environment Variables  
```bash
export GCP_PROJECT_ID="world-fishing-827"
export BQ_DATASET="tech_anomaly_detection"
export DBT_ENVIRONMENT="prod"
```

## Configuration Files to Update

When setting up a new project, you may need to update dataset references in:

- `dataloader/ci/executor/config_dev.yaml` - Update BigQuery dataset references
- `dbt/seeds/*` - Environment-specific threshold and configuration files
- Terraform variable files in each environment directory

## Troubleshooting

### Common Issues

1. **Permission Denied**: Ensure service account has all required roles
2. **BigQuery Dataset Not Found**: Verify dataset exists and project ID is correct
3. **Cloud Run Deployment Fails**: Check Docker image registry permissions
4. **DBT Seed Fails**: Verify DBT_ENVIRONMENT is set correctly

### Useful Commands

```bash
# Check current project
gcloud config get-value project

# List BigQuery datasets
bq ls

# Check Cloud Run jobs
gcloud run jobs list

# View Cloud Scheduler jobs
gcloud scheduler jobs list
```