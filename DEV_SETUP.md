# Development Environment Setup

This guide helps you set up your own GCP project for anomaly detection development and testing.

## Prerequisites

- GCP account with billing enabled
- gcloud CLI installed and configured
- Docker installed locally
- Terraform installed

## Quick Setup Options

### Option A: Automated Setup (Recommended)

Use the automated setup script for existing GCP projects:

```bash
# For existing GCP project
./scripts/setup-new-project.sh your-project-id
```

### Option B: Manual Setup

<details>
<summary>Click to expand manual setup steps (5-10 minutes)</summary>

#### 1. Create GCP Project

```bash
# Create project (replace with your preferred ID)
export PROJECT_ID="anomaly-detection-dev-$(date +%s)"
gcloud projects create $PROJECT_ID --name="Anomaly Detection Dev"
gcloud config set project $PROJECT_ID

# Enable billing in GCP Console if needed
echo "Enable billing for project $PROJECT_ID at:"
echo "https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID"
```

#### 2. Enable APIs & Setup Service Account

```bash
# Enable APIs
gcloud services enable \
  bigquery.googleapis.com \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  cloudscheduler.googleapis.com \
  secretmanager.googleapis.com \
  storage.googleapis.com

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

#### 3. Create Project Configuration

```bash
# Create project-specific config directory
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

#### 4. Setup Environment

```bash
# Use the project switcher to activate your project
source scripts/set-project.sh $PROJECT_ID

# Create BigQuery dataset
bq mk --location=US --dataset $PROJECT_ID:tech_anomaly_detection

# Generate backend configurations for Terraform
./scripts/generate-backend-configs.sh $PROJECT_ID
```

#### 5. Bootstrap Remote State

```bash
# Create remote state bucket (one-time setup)
cd terraform/bootstrap
terraform init
terraform apply -var="project=$PROJECT_ID"
cd ../..
```

</details>

## Test Your Setup

### Option A: Test Dataloader Component

```bash
cd dataloader/ci/executor && docker-compose up
```

### Option B: Manual Test

```bash
# Activate your project
source scripts/set-project.sh your-project-id

# Test dataloader
./scripts/docker-run.sh dataloader

# Check results in BigQuery
bq query --use_legacy_sql=false "SELECT * FROM \`$PROJECT_ID.tech_anomaly_detection.t_dev_forecasts\` LIMIT 10"
```

## Development Workflow

### Local Development

```bash
# Always activate your project first
source scripts/set-project.sh your-project-id

# Test dataloader locally
./scripts/docker-run.sh dataloader

# Test alerting locally (optional - requires Slack setup)
./scripts/docker-run.sh alerting
```

### DBT Development

```bash
cd dbt
source setenv.sh  # Sets DBT_ENVIRONMENT based on git branch
dbt seed          # Deploy lookup tables using project-specific seeds
```

### Infrastructure Deployment

```bash
# Ensure project is active and backend configs are generated
source scripts/set-project.sh your-project-id
./scripts/generate-backend-configs.sh your-project-id

# Deploy dataloader infrastructure
cd dataloader/deploy/environments/dev
terraform init
terraform apply -var-file="../../../../configs/$ANOMALY_PROJECT/terraform.tfvars"

# Deploy alerting infrastructure
cd ../../../../alerting/deploy/environments/dev
terraform init
terraform apply -var-file="../../../../configs/$ANOMALY_PROJECT/terraform.tfvars"
```

## Multi-Project Configuration

This system supports multiple projects simultaneously:

### Project Structure
```
configs/
├── your-project-id/           # Your development project
├── anomaly-detection-demo/    # Demo project (public data)
├── world-fishing-827/         # GFW production (if applicable)
└── template/                  # Template for new projects
```

### Switching Projects
```bash
# Switch to your project
source scripts/set-project.sh your-project-id

# Switch to demo project
source scripts/set-project.sh anomaly-detection-demo-461518

# All subsequent operations use the active project's configurations
```

### Project-Specific Files
- **Terraform Variables**: `configs/{project}/terraform.tfvars`
- **DBT Seeds**: `configs/{project}/dbt_seeds/`
- **Dataloader Configs**: `configs/{project}/dataloader/`

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

**"Backend configuration not found"**
- Run: `./scripts/generate-backend-configs.sh your-project-id`
- Ensure remote state bucket exists: `cd terraform/bootstrap && terraform apply`

**Docker build failures**
- Ensure Docker is running
- Check internet connectivity
- Try rebuilding: `docker-compose build --no-cache`

**BigQuery access issues**
- Verify dataset exists: `bq ls $PROJECT_ID:tech_anomaly_detection`
- Check project ID is correct: `gcloud config get-value project`

**"No active project" errors**
- Run: `source scripts/set-project.sh your-project-id`
- Check: `echo $ANOMALY_PROJECT`

### Useful Commands

```bash
# Check current setup
echo "Active Project: $ANOMALY_PROJECT"
echo "GCP Project: $(gcloud config get-value project)"
echo "Account: $(gcloud config get-value account)"

# List available project configurations
ls configs/

# List BigQuery datasets
bq ls

# Check Docker containers
docker ps

# View recent logs
docker-compose logs
```

## Next Steps

1. **Test the components** using docker-compose to verify everything works
2. **Explore the data** in BigQuery Console
3. **Modify configs** in `configs/your-project-id/dataloader/` to try different data sources  
4. **Set up alerting** by configuring Slack integration
5. **Deploy to Cloud Run** using the Terraform infrastructure

## Advanced Configuration

### Custom Data Sources
Create your own anomaly detection configurations:
```bash
# Copy demo config as starting point
cp configs/anomaly-detection-demo-461518/dataloader/config_demo.yaml \
   configs/$PROJECT_ID/dataloader/config_dev.yaml

# Edit to point to your data sources
```

### Multiple Environments
```bash
# Deploy to staging
cd dataloader/deploy/environments/main
terraform apply -var-file="../../../../configs/$ANOMALY_PROJECT/terraform.tfvars"
```

## Support

- Review component-specific READMEs in `alerting/README.md` and `dataloader/README.md`
- Review `PROJECT_SETUP.md` for full production setup
- See `configs/template/README.md` for new project setup guide
- Use `./scripts/setup-new-project.sh --help` for automated setup options