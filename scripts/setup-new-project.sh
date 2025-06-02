#!/bin/bash

# Anomaly Detection - New Project Setup Script
# This script automates the complete setup process for a new project

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    # Check if gcloud is installed
    if ! command -v gcloud &> /dev/null; then
        print_error "gcloud CLI is required but not installed"
        exit 1
    fi
    
    # Check if terraform is installed
    if ! command -v terraform &> /dev/null; then
        print_error "Terraform is required but not installed"
        exit 1
    fi
    
    # Check if we're in the right directory
    if [ ! -f "dbt/dbt_project.yml" ]; then
        print_error "Please run this script from the anomaly detection repository root"
        exit 1
    fi
    
    print_success "Prerequisites check passed"
}

# Collect user inputs
collect_inputs() {
    print_status "Setting up new anomaly detection project..."
    echo ""
    
    # Project ID
    read -p "Enter your GCP project ID: " PROJECT_ID
    if [ -z "$PROJECT_ID" ]; then
        print_error "Project ID is required"
        exit 1
    fi
    
    # User email
    read -p "Enter your email for authentication: " USER_EMAIL
    if [ -z "$USER_EMAIL" ]; then
        print_error "User email is required"
        exit 1
    fi
    
    # Region
    read -p "Enter GCP region [us-central1]: " REGION
    REGION=${REGION:-us-central1}
    
    # Environments
    read -p "Enter environments (comma-separated) [dev,staging,prod]: " ENVIRONMENTS
    ENVIRONMENTS=${ENVIRONMENTS:-dev,staging,prod}
    
    # Service account name
    read -p "Enter service account name [anomaly-detection]: " SA_NAME
    SA_NAME=${SA_NAME:-anomaly-detection}
    
    # Dataset name
    read -p "Enter BigQuery dataset name [tech_anomaly_detection]: " DATASET_NAME
    DATASET_NAME=${DATASET_NAME:-tech_anomaly_detection}
    
    echo ""
    print_status "Configuration summary:"
    echo "  Project ID: $PROJECT_ID"
    echo "  User Email: $USER_EMAIL"
    echo "  Region: $REGION"
    echo "  Environments: $ENVIRONMENTS"
    echo "  Service Account: $SA_NAME"
    echo "  Dataset: $DATASET_NAME"
    echo ""
    
    read -p "Continue with setup? (y/N): " CONFIRM
    if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
        print_status "Setup cancelled"
        exit 0
    fi
}

# Setup GCP authentication
setup_gcp_auth() {
    print_status "Setting up GCP authentication..."
    
    # Create gcloud configuration
    CONFIG_NAME="anomaly-${PROJECT_ID}"
    print_status "Creating gcloud configuration: $CONFIG_NAME"
    
    if gcloud config configurations describe "$CONFIG_NAME" &>/dev/null; then
        print_warning "Configuration $CONFIG_NAME already exists, updating..."
    else
        gcloud config configurations create "$CONFIG_NAME"
    fi
    
    gcloud config configurations activate "$CONFIG_NAME"
    gcloud config set account "$USER_EMAIL"
    gcloud config set project "$PROJECT_ID"
    
    print_status "Please authenticate when prompted..."
    gcloud auth login --account="$USER_EMAIL"
    gcloud auth application-default login
    
    print_success "GCP authentication configured"
}

# Setup GCP project
setup_gcp_project() {
    print_status "Setting up GCP project..."
    
    # Enable required APIs
    print_status "Enabling required APIs..."
    gcloud services enable bigquery.googleapis.com \
        cloudbuild.googleapis.com \
        run.googleapis.com \
        cloudscheduler.googleapis.com \
        secretmanager.googleapis.com \
        storage.googleapis.com
    
    # Create BigQuery dataset
    print_status "Creating BigQuery dataset: $DATASET_NAME"
    if ! bq ls "$PROJECT_ID:$DATASET_NAME" &>/dev/null; then
        bq mk --location="$REGION" --dataset "$PROJECT_ID:$DATASET_NAME"
    else
        print_warning "Dataset $DATASET_NAME already exists"
    fi
    
    # Create service account
    print_status "Creating service account: $SA_NAME"
    SERVICE_ACCOUNT_EMAIL="$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"
    
    if ! gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" &>/dev/null; then
        gcloud iam service-accounts create "$SA_NAME" \
            --description="Anomaly Detection Service Account" \
            --display-name="Anomaly Detection"
        
        # Grant necessary permissions
        gcloud projects add-iam-policy-binding "$PROJECT_ID" \
            --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
            --role="roles/bigquery.dataEditor"
        
        gcloud projects add-iam-policy-binding "$PROJECT_ID" \
            --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
            --role="roles/bigquery.jobUser"
        
        gcloud projects add-iam-policy-binding "$PROJECT_ID" \
            --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
            --role="roles/run.invoker"
        
        gcloud projects add-iam-policy-binding "$PROJECT_ID" \
            --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
            --role="roles/secretmanager.secretAccessor"
    else
        print_warning "Service account $SERVICE_ACCOUNT_EMAIL already exists"
    fi
    
    print_success "GCP project setup completed"
}

# Create project directory structure
create_project_structure() {
    print_status "Creating project directory structure..."
    
    PROJECT_DIR="configs/$PROJECT_ID"
    mkdir -p "$PROJECT_DIR"/{dbt_seeds,dataloader,alerting}
    
    # Create terraform.tfvars
    cat > "$PROJECT_DIR/terraform.tfvars" << EOF
# Project Configuration for $PROJECT_ID
project               = "$PROJECT_ID"
region                = "$REGION"
service_account_email = "$SERVICE_ACCOUNT_EMAIL"
docker_registry       = "gcr.io/$PROJECT_ID"
EOF
    
    # Create template seed files for each environment
    IFS=',' read -ra ENV_ARRAY <<< "$ENVIRONMENTS"
    for env in "${ENV_ARRAY[@]}"; do
        env=$(echo "$env" | xargs) # trim whitespace
        
        # Create config descriptions
        cat > "$PROJECT_DIR/dbt_seeds/config_descriptions_$env.csv" << EOF
config_name,description
sample_daily_metrics,"Sample configuration for daily metrics monitoring. Replace with your actual data sources."
EOF
        
        # Create thresholds
        cat > "$PROJECT_DIR/dbt_seeds/thresholds_$env.csv" << EOF
config_name,forecast_method,critical_lower,critical_higher,warning_lower,warning_higher
sample_daily_metrics,median,-0.5,0.5,-0.3,0.3
EOF
    done
    
    # Create sample dataloader config
    cat > "$PROJECT_DIR/dataloader/config_dev.yaml" << EOF
anomalies:
  sample_daily_metrics:
    source_dataset: "$DATASET_NAME"
    source_table: "sample_data"
    source_timestamp_column: "date"
    source_timestamp_column_sql: 'TIMESTAMP(date)'
    source_forecast_column: "value"
    source_forecast_column_sql: "SUM(value)"
    period_length: "day"
    algorithms:
      median:
        parameters:
          sliding_window: 14
      mean:
        parameters:
          sliding_window: 14
EOF
    
    # Create Slack channel mapping
    cat > "$PROJECT_DIR/dbt_seeds/slack_channels_environments_config_mapping.csv" << EOF
config_name,environment,slack_channel_id,slack_channel_name
sample_daily_metrics,dev,YOUR_SLACK_CHANNEL_ID,your-alerts-channel
EOF
    
    print_success "Project directory structure created"
}

# Setup Terraform remote state
setup_terraform_state() {
    print_status "Setting up Terraform remote state..."
    
    # Update bootstrap terraform.tfvars
    cat > "terraform/bootstrap/terraform.tfvars" << EOF
project_id = "$PROJECT_ID"
region     = "$REGION"
EOF
    
    # Deploy bootstrap
    cd terraform/bootstrap
    terraform init
    terraform plan -out=tfplan
    terraform apply tfplan
    cd ../..
    
    print_success "Terraform remote state bucket created"
}

# Setup DBT profile
setup_dbt_profile() {
    print_status "Setting up DBT profile..."
    
    DBT_PROFILE_NAME="anomaly_detection_$PROJECT_ID"
    DBT_PROFILE_NAME=$(echo "$DBT_PROFILE_NAME" | sed 's/-/_/g') # Replace hyphens with underscores
    
    # Check if profiles.yml exists
    if [ ! -f ~/.dbt/profiles.yml ]; then
        mkdir -p ~/.dbt
        touch ~/.dbt/profiles.yml
    fi
    
    # Add profile if it doesn't exist
    if ! grep -q "$DBT_PROFILE_NAME:" ~/.dbt/profiles.yml; then
        cat >> ~/.dbt/profiles.yml << EOF

$DBT_PROFILE_NAME:
  outputs:
    dev:
      dataset: $DATASET_NAME
      job_execution_timeout_seconds: 1800
      job_retries: 1
      location: US
      method: oauth
      priority: interactive
      project: $PROJECT_ID
      threads: 1
      type: bigquery
    staging:
      dataset: $DATASET_NAME
      job_execution_timeout_seconds: 1800
      job_retries: 1
      location: US
      method: oauth
      priority: interactive
      project: $PROJECT_ID
      threads: 1
      type: bigquery
    prod:
      dataset: $DATASET_NAME
      job_execution_timeout_seconds: 1800
      job_retries: 1
      location: US
      method: oauth
      priority: interactive
      project: $PROJECT_ID
      threads: 1
      type: bigquery
  target: dev
EOF
        print_success "DBT profile created: $DBT_PROFILE_NAME"
    else
        print_warning "DBT profile $DBT_PROFILE_NAME already exists"
    fi
}

# Create project-specific scripts
create_project_scripts() {
    print_status "Creating project-specific convenience scripts..."
    
    PROJECT_DIR="configs/$PROJECT_ID"
    
    # Create activate script
    cat > "$PROJECT_DIR/activate.sh" << EOF
#!/bin/bash
# Activate $PROJECT_ID anomaly detection environment

echo "Activating anomaly detection environment for: $PROJECT_ID"

# Switch gcloud configuration
gcloud config configurations activate anomaly-$PROJECT_ID

# Set project environment
export ANOMALY_PROJECT="$PROJECT_ID"
export ANOMALY_PROJECT_CONFIG_DIR="configs/$PROJECT_ID"

echo "Environment activated:"
echo "  GCP Project: \$(gcloud config get-value project)"
echo "  Anomaly Project: \$ANOMALY_PROJECT"
echo ""
echo "Next steps:"
echo "  1. Deploy DBT seeds: cd dbt && source setenv.sh && dbt seed --profile $DBT_PROFILE_NAME"
echo "  2. Configure your data sources in: configs/$PROJECT_ID/dataloader/"
echo "  3. Run dataloader: ./scripts/docker-run.sh dataloader"
EOF
    
    chmod +x "$PROJECT_DIR/activate.sh"
    
    print_success "Project scripts created"
}

# Create project documentation
create_project_docs() {
    print_status "Creating project documentation..."
    
    PROJECT_DIR="configs/$PROJECT_ID"
    
    cat > "$PROJECT_DIR/README.md" << EOF
# Anomaly Detection Project: $PROJECT_ID

This directory contains the complete configuration for the $PROJECT_ID anomaly detection setup.

## Quick Start

1. **Activate Environment**:
   \`\`\`bash
   source configs/$PROJECT_ID/activate.sh
   \`\`\`

2. **Deploy DBT Configuration**:
   \`\`\`bash
   cd dbt
   source setenv.sh
   dbt seed --profile $DBT_PROFILE_NAME
   \`\`\`

3. **Configure Your Data Sources**:
   - Edit \`dataloader/config_dev.yaml\` with your actual data sources
   - Update \`dbt_seeds/config_descriptions_dev.csv\` with your metric descriptions
   - Adjust \`dbt_seeds/thresholds_dev.csv\` with appropriate thresholds

4. **Run Anomaly Detection**:
   \`\`\`bash
   ./scripts/docker-run.sh dataloader
   \`\`\`

## Configuration Files

- \`terraform.tfvars\`: Infrastructure configuration
- \`dbt_seeds/\`: DBT seed files for thresholds and descriptions
- \`dataloader/\`: R-based anomaly detection configurations
- \`activate.sh\`: Environment activation script

## Environments

Available environments: $ENVIRONMENTS

Switch environments by updating the DBT_ENVIRONMENT variable and using the appropriate config files.

## GCP Resources Created

- **Project**: $PROJECT_ID
- **Dataset**: $DATASET_NAME
- **Service Account**: $SERVICE_ACCOUNT_EMAIL
- **Terraform State Bucket**: $PROJECT_ID-tfstate

## Support

For questions and issues, refer to the main repository documentation.
EOF
    
    print_success "Project documentation created"
}

# Main execution
main() {
    echo "========================================"
    echo "  Anomaly Detection - New Project Setup"
    echo "========================================"
    echo ""
    
    check_prerequisites
    collect_inputs
    setup_gcp_auth
    setup_gcp_project
    create_project_structure
    setup_terraform_state
    setup_dbt_profile
    create_project_scripts
    create_project_docs
    
    echo ""
    print_success "Project setup completed successfully!"
    echo ""
    echo "Next steps:"
    echo "1. Activate your environment: source configs/$PROJECT_ID/activate.sh"
    echo "2. Review and customize: configs/$PROJECT_ID/README.md"
    echo "3. Configure your data sources in: configs/$PROJECT_ID/dataloader/"
    echo "4. Deploy and test: cd dbt && dbt seed --profile $DBT_PROFILE_NAME"
    echo ""
    echo "Your anomaly detection project is ready!"
}

# Run main function
main "$@"