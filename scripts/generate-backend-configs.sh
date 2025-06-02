#!/bin/bash

# Backend configuration generator for multi-project support
# Usage: ./scripts/generate-backend-configs.sh <project-id>

set -e

PROJECT_ID="$1"

if [ -z "$PROJECT_ID" ]; then
    echo "Usage: $0 <project-id>"
    echo "Example: $0 anomaly-detection-demo-461518"
    exit 1
fi

# Determine state bucket based on project
if [ "$PROJECT_ID" = "world-fishing-827" ]; then
    # CRITICAL: Preserve exact same bucket for GFW deployment
    STATE_BUCKET="skytruth-pelagos-production-tfstate-us-central1"
    echo "Using existing GFW state bucket: $STATE_BUCKET"
else
    # New projects get their own state bucket
    STATE_BUCKET="${PROJECT_ID}-tfstate"
    echo "Using project-specific state bucket: $STATE_BUCKET"
fi

echo "Generating backend configurations for project: $PROJECT_ID"

# Find all backend.tf.template files and generate backend.tf files
template_count=0
find . -name "backend.tf.template" | while read template_file; do
    target_file="${template_file%.template}"
    
    echo "  $template_file -> $target_file"
    
    # Replace placeholder with actual bucket name
    sed "s|{{STATE_BUCKET}}|$STATE_BUCKET|g" "$template_file" > "$target_file"
    
    template_count=$((template_count + 1))
done

echo "Generated backend configurations for $template_count files"
echo ""
echo "IMPORTANT: For world-fishing-827, this preserves the exact same state bucket"
echo "           ensuring no disruption to existing deployments."