# GCP Project Setup Guide

This guide explains how to set up a new GCP project for anomaly detection development and testing.

## Quick Setup (Recommended)

For fastest setup, use the automated script:

```bash
./scripts/setup-new-project.sh your-project-id
```

This handles all steps below automatically. Continue reading for manual setup or troubleshooting.

## Prerequisites

- GCP account with project creation permissions
- Terraform installed
- gcloud CLI configured
- Docker installed for local development

## Manual Setup Steps

<details>
<summary>Click to expand manual setup steps</summary>

### Step 1: Create GCP Project

1. Create a new GCP project:
   ```bash
   export PROJECT_ID="your-dev-project-id"
   gcloud projects create $PROJECT_ID --name="Anomaly Detection Dev"
   gcloud config set project $PROJECT_ID
   ```

2. Enable required APIs:
   ```bash
   gcloud services enable bigquery.googleapis.com \
     cloudbuild.googleapis.com \
     run.googleapis.com \
     cloudscheduler.googleapis.com \
     secretmanager.googleapis.com \
     storage.googleapis.com \
     --project=$PROJECT_ID
   ```

### Step 2: Create Service Account

1. Create service account:
   ```bash
   gcloud iam service-accounts create anomaly-detection \
     --description="Anomaly Detection Service Account" \
     --display-name="Anomaly Detection" \
     --project=$PROJECT_ID
   ```

2. Grant necessary permissions:
   ```bash
   # BigQuery permissions
   gcloud projects add-iam-policy-binding $PROJECT_ID \
     --member="serviceAccount:anomaly-detection@$PROJECT_ID.iam.gserviceaccount.com" \
     --role="roles/bigquery.dataEditor"
   
   gcloud projects add-iam-policy-binding $PROJECT_ID \
     --member="serviceAccount:anomaly-detection@$PROJECT_ID.iam.gserviceaccount.com" \
     --role="roles/bigquery.jobUser"
   
   # Cloud Run permissions
   gcloud projects add-iam-policy-binding $PROJECT_ID \
     --member="serviceAccount:anomaly-detection@$PROJECT_ID.iam.gserviceaccount.com" \
     --role="roles/run.invoker"
   
   # Secret Manager permissions (for Slack token)
   gcloud projects add-iam-policy-binding $PROJECT_ID \
     --member="serviceAccount:anomaly-detection@$PROJECT_ID.iam.gserviceaccount.com" \
     --role="roles/secretmanager.secretAccessor"
   ```

### Step 3: Create BigQuery Dataset

```bash
bq mk --location=US --dataset $PROJECT_ID:tech_anomaly_detection
```

### Step 4: Create Project Configuration

Create project-specific configuration directory and files:

```bash
# Create config directory structure
mkdir -p configs/$PROJECT_ID/{dataloader,dbt_seeds}

# Create terraform.tfvars for your project
cat > configs/$PROJECT_ID/terraform.tfvars << EOF
# Project Configuration
project               = "$PROJECT_ID"
region                = "us-central1"
service_account_email = "anomaly-detection@$PROJECT_ID.iam.gserviceaccount.com"
docker_registry       = "gcr.io/$PROJECT_ID"
anomaly_alerting_project_name = "anomaly-detection-alerting"
anomaly_dataloader_project_name = "anomaly-detection-dataloader"
EOF
```

### Step 5: Setup Terraform Backend

1. Activate your project:
   ```bash
   source scripts/set-project.sh $PROJECT_ID
   ```

2. Bootstrap remote state storage:
   ```bash
   cd terraform/bootstrap
   terraform init
   terraform apply -var="project=$PROJECT_ID"
   cd ../..
   ```

3. Generate backend configurations:
   ```bash
   ./scripts/generate-backend-configs.sh $PROJECT_ID
   ```

### Step 6: Setup Slack Integration (Optional)

1. Create a Slack app and get bot token
2. Store in Secret Manager:
   ```bash
   echo "your-slack-bot-token" | gcloud secrets create QA_SLACK_BOT_USER_OAUTH_TOKEN \
     --data-file=- --project=$PROJECT_ID
   ```

### Step 7: Deploy Infrastructure

Ensure your project is active and deploy the infrastructure:

```bash
# Verify project is active
echo "Active project: $ANOMALY_PROJECT"

# Deploy dataloader infrastructure
cd dataloader/deploy/environments/dev
terraform init
terraform apply -var-file="../../../../configs/$ANOMALY_PROJECT/terraform.tfvars"

# Deploy alerting infrastructure
cd ../../../../alerting/deploy/environments/dev  
terraform init
terraform apply -var-file="../../../../configs/$ANOMALY_PROJECT/terraform.tfvars"
```

### Step 8: Configure DBT

1. Copy seed files from demo project:
   ```bash
   cp configs/anomaly-detection-demo-461518/dbt_seeds/* \
      configs/$PROJECT_ID/dbt_seeds/
   ```

2. Set up DBT environment and deploy seeds:
   ```bash
   cd dbt
   source setenv.sh  # Sets DBT_ENVIRONMENT based on git branch
   dbt seed
   cd ..
   ```

### Step 9: Test the Setup

1. Test dataloader:
   ```bash
   # Ensure project is active
   source scripts/set-project.sh $PROJECT_ID
   
   # Run dataloader
   ./scripts/docker-run.sh dataloader
   ```

2. Verify results in BigQuery:
   ```bash
   bq query --use_legacy_sql=false \
     "SELECT * FROM \`$PROJECT_ID.tech_anomaly_detection.t_dev_forecasts\` LIMIT 10"
   ```

3. Test alerting (optional):
   ```bash
   ./scripts/docker-run.sh alerting
   ```

</details>

## Multi-Project Architecture

This system supports multiple projects with complete isolation:

### Project Structure
```
configs/
├── your-project-id/           # Your project
├── anomaly-detection-demo/    # Demo project (public data)
├── world-fishing-827/         # GFW production (if applicable)
└── template/                  # Template for new projects
```

### Environment Variables
The system uses project-specific environment variables:

```bash
# Automatically set by: source scripts/set-project.sh your-project-id
export ANOMALY_PROJECT="your-project-id"
export GCP_PROJECT_ID="your-project-id"
export BQ_DATASET="tech_anomaly_detection"
```

### Environment Configurations

Each project supports multiple environments (dev, staging, prod):

**Development Environment**
```bash
source scripts/set-project.sh your-project-id
# Uses: configs/your-project-id/terraform.tfvars
# Deploys to: dev environment
```

**Staging/Production Environment**
```bash
# Deploy to staging
cd dataloader/deploy/environments/main
terraform apply -var-file="../../../../configs/$ANOMALY_PROJECT/terraform.tfvars"

# Deploy to production
cd ../release
terraform apply -var-file="../../../../configs/$ANOMALY_PROJECT/terraform.tfvars"
```

## Configuration Files

When setting up a new project, these files are automatically created:

### Required Files
- `configs/{project}/terraform.tfvars` - Infrastructure variables
- `configs/{project}/dbt_seeds/` - Environment-specific lookup tables
- `configs/{project}/dataloader/` - Data source configurations

### Optional Customizations
- Custom anomaly detection configurations
- Project-specific Slack channel mappings
- Environment-specific thresholds

## Deployment Architecture

### Remote State Management
Each project gets its own Terraform state bucket:
- **GFW**: `skytruth-pelagos-production-tfstate-us-central1` (preserved)
- **New Projects**: `{project-id}-tfstate` (isolated)

### Infrastructure Components
- **BigQuery Tables**: `t_{environment}_forecasts`, `t_{environment}_actuals`
- **Cloud Run Jobs**: Project-specific naming with configurable prefixes
- **Cloud Scheduler**: Automated forecasting schedules
- **Secret Manager**: Slack tokens and other secrets

## Troubleshooting

### Common Issues

1. **Permission Denied**: Ensure service account has all required roles
2. **Backend Not Found**: Run `./scripts/generate-backend-configs.sh your-project-id`
3. **BigQuery Dataset Missing**: Verify dataset exists with `bq ls`
4. **Project Not Active**: Run `source scripts/set-project.sh your-project-id`
5. **Terraform State Issues**: Ensure bootstrap step completed successfully

### Useful Commands

```bash
# Check current project setup
echo "Active Project: $ANOMALY_PROJECT"
echo "GCP Project: $(gcloud config get-value project)"

# List available projects
ls configs/

# Check infrastructure status
cd dataloader/deploy/environments/dev && terraform plan
cd ../../../../alerting/deploy/environments/dev && terraform plan

# View BigQuery datasets
bq ls

# Check Cloud Run jobs
gcloud run jobs list
```

### Recovery Commands

```bash
# Reset project activation
source scripts/set-project.sh your-project-id

# Regenerate backend configs
./scripts/generate-backend-configs.sh your-project-id

# Reinitialize Terraform
cd dataloader/deploy/environments/dev
terraform init -reconfigure
```

## Advanced Configuration

### Custom Data Sources
```bash
# Copy demo config as starting point
cp configs/anomaly-detection-demo-461518/dataloader/config_demo.yaml \
   configs/$PROJECT_ID/dataloader/config_dev.yaml

# Edit to point to your specific BigQuery tables
```

### Production Deployment
```bash
# Deploy Cloud Build triggers for CI/CD
cd cloudbuild
terraform init
terraform apply -var-file="../configs/$ANOMALY_PROJECT/terraform.tfvars"
```

### Custom Resource Naming
Update your `terraform.tfvars` to customize resource names:
```hcl
anomaly_alerting_project_name = "your-org-anomaly-alerting"
anomaly_dataloader_project_name = "your-org-anomaly-dataloader"
additional_users = ["user:admin@your-org.com"]
```

## Support

- **Quick Setup**: Use `./scripts/setup-new-project.sh your-project-id`
- **Development**: See `DEV_SETUP.md` for daily development workflow
- **Demo**: Try `configs/anomaly-detection-demo-461518` for working example
- **Templates**: Check `configs/template/README.md` for customization guide