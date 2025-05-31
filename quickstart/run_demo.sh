#!/bin/bash

# Quickstart Demo Runner for Anomaly Detection
# This script demonstrates the complete workflow using public BigQuery data

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

echo_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

echo_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    echo_info "Checking prerequisites..."
    
    if ! command -v gcloud &> /dev/null; then
        echo_error "gcloud CLI not found. Please install Google Cloud SDK."
        exit 1
    fi
    
    if ! command -v bq &> /dev/null; then
        echo_error "bq CLI not found. Please install Google Cloud SDK with BigQuery component."
        exit 1
    fi
    
    if ! command -v docker &> /dev/null; then
        echo_error "Docker not found. Please install Docker."
        exit 1
    fi
    
    if [[ -z "${GCP_PROJECT_ID}" ]]; then
        echo_error "GCP_PROJECT_ID environment variable not set."
        echo_info "Please run: export GCP_PROJECT_ID='your-project-id'"
        exit 1
    fi
    
    echo_success "Prerequisites check passed"
}

# Verify GCP setup
verify_gcp_setup() {
    echo_info "Verifying GCP setup..."
    
    # Check if project exists and is accessible
    if ! gcloud projects describe "${GCP_PROJECT_ID}" &> /dev/null; then
        echo_error "Cannot access project ${GCP_PROJECT_ID}. Please check project ID and permissions."
        exit 1
    fi
    
    # Check if BigQuery API is enabled
    if ! gcloud services list --enabled --filter="name:bigquery.googleapis.com" --project="${GCP_PROJECT_ID}" | grep -q bigquery; then
        echo_warning "BigQuery API not enabled. Attempting to enable..."
        gcloud services enable bigquery.googleapis.com --project="${GCP_PROJECT_ID}"
    fi
    
    echo_success "GCP setup verified"
}

# Create BigQuery dataset if needed
setup_bigquery_dataset() {
    local dataset="${BQ_DATASET:-anomaly_detection_demo}"
    
    echo_info "Setting up BigQuery dataset: ${dataset}"
    
    if ! bq ls -d "${GCP_PROJECT_ID}:${dataset}" &> /dev/null; then
        echo_info "Creating dataset ${dataset}..."
        bq mk --location=US --dataset "${GCP_PROJECT_ID}:${dataset}"
        echo_success "Dataset created: ${GCP_PROJECT_ID}:${dataset}"
    else
        echo_info "Dataset already exists: ${GCP_PROJECT_ID}:${dataset}"
    fi
}

# Run the anomaly detection demo
run_anomaly_detection() {
    echo_info "Running anomaly detection demo..."
    
    # Build and run the demo
    docker-compose up --build dataloader-demo
    
    echo_success "Anomaly detection completed"
}

# Display results
show_results() {
    echo_info "Displaying demo results..."
    
    docker-compose --profile results up results-viewer
    
    echo_success "Demo completed successfully!"
    echo_info "You can now:"
    echo "  1. Explore data in BigQuery Console: https://console.cloud.google.com/bigquery?project=${GCP_PROJECT_ID}"
    echo "  2. Query results: bq query --use_legacy_sql=false 'SELECT * FROM \`${GCP_PROJECT_ID}.${BQ_DATASET:-anomaly_detection_demo}.t_demo_forecasts\` LIMIT 10'"
    echo "  3. Set up alerting by following the main PROJECT_SETUP.md guide"
}

# Cleanup function
cleanup() {
    echo_info "Cleaning up Docker containers..."
    docker-compose down --remove-orphans
}

# Main execution
main() {
    echo_info "Starting Anomaly Detection Quickstart Demo"
    echo_info "Project: ${GCP_PROJECT_ID}"
    echo_info "Dataset: ${BQ_DATASET:-anomaly_detection_demo}"
    echo ""
    
    # Set trap for cleanup on exit
    trap cleanup EXIT
    
    check_prerequisites
    verify_gcp_setup
    setup_bigquery_dataset
    run_anomaly_detection
    show_results
}

# Run main function
main "$@"