#!/bin/bash

# Terraform state bucket validation script
# Usage: ./scripts/validate-project-state.sh <project-id>

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

PROJECT_ID="$1"

if [ -z "$PROJECT_ID" ]; then
    echo "Usage: $0 <project-id>"
    echo "Example: $0 anomaly-detection-demo-461518"
    echo ""
    echo "Available projects:"
    ls -1 configs/ | grep -v template | grep -v README.md
    exit 1
fi

print_status "Validating Terraform state configuration for project: $PROJECT_ID"

# Check if project config directory exists
if [ ! -d "configs/$PROJECT_ID" ]; then
    print_error "Project configuration directory not found: configs/$PROJECT_ID"
    print_status "Available projects:"
    ls -1 configs/ | grep -v template | grep -v README.md
    exit 1
fi

# Determine expected bucket name
if [ "$PROJECT_ID" = "world-fishing-827" ]; then
    EXPECTED_BUCKET="skytruth-pelagos-production-tfstate-us-central1"
    print_status "Checking GFW production state bucket: $EXPECTED_BUCKET"
else
    EXPECTED_BUCKET="${PROJECT_ID}-tfstate"
    print_status "Checking project-specific state bucket: $EXPECTED_BUCKET"
fi

# Check if bucket exists
print_status "Verifying state bucket exists..."
if gsutil ls "gs://$EXPECTED_BUCKET" &>/dev/null; then
    print_success "State bucket exists: gs://$EXPECTED_BUCKET"
else
    print_error "State bucket not found: gs://$EXPECTED_BUCKET"
    print_status ""
    print_status "To create the bucket, run:"
    print_status "  cd terraform/bootstrap"
    print_status "  terraform init"
    print_status "  terraform apply -var=\"project=$PROJECT_ID\""
    exit 1
fi

# Check if backend configurations exist
print_status "Checking backend configurations..."
backend_files=(
    "alerting/deploy/environments/dev/backend.tf"
    "alerting/deploy/environments/main/backend.tf"
    "alerting/deploy/environments/release/backend.tf"
    "dataloader/deploy/environments/dev/backend.tf"
    "dataloader/deploy/environments/main/backend.tf"
    "dataloader/deploy/environments/release/backend.tf"
)

missing_backends=0
incorrect_backends=0

for backend_file in "${backend_files[@]}"; do
    if [ -f "$backend_file" ]; then
        if grep -q "$EXPECTED_BUCKET" "$backend_file"; then
            print_success "✓ $backend_file (correct bucket)"
        else
            print_error "✗ $backend_file (incorrect bucket)"
            actual_bucket=$(grep "bucket" "$backend_file" | sed 's/.*"\(.*\)".*/\1/')
            print_status "    Expected: $EXPECTED_BUCKET"
            print_status "    Found: $actual_bucket"
            incorrect_backends=$((incorrect_backends + 1))
        fi
    else
        print_error "✗ $backend_file (missing)"
        missing_backends=$((missing_backends + 1))
    fi
done

# Check if backend templates exist
print_status "Checking backend templates..."
template_count=$(find . -name "backend.tf.template" | wc -l)
if [ "$template_count" -gt 0 ]; then
    print_success "Found $template_count backend templates"
else
    print_warning "No backend templates found"
fi

# Summary and recommendations
echo ""
print_status "Validation Summary:"
echo "  Project: $PROJECT_ID"
echo "  State Bucket: $EXPECTED_BUCKET"
echo "  Missing Backends: $missing_backends"
echo "  Incorrect Backends: $incorrect_backends"

if [ "$missing_backends" -gt 0 ] || [ "$incorrect_backends" -gt 0 ]; then
    echo ""
    print_error "Backend configuration issues detected!"
    print_status ""
    print_status "To fix backend configurations, run:"
    print_status "  ./scripts/generate-backend-configs.sh $PROJECT_ID"
    exit 1
else
    echo ""
    print_success "All backend configurations are correct!"
    print_status ""
    print_status "You can now safely run Terraform operations:"
    print_status "  cd dataloader/deploy/environments/dev"
    print_status "  terraform init"
    print_status "  terraform apply -var-file=\"../../../../configs/$PROJECT_ID/terraform.tfvars\""
fi