#!/bin/bash

# Multi-Project Anomaly Detection Quick Start
# This script demonstrates the new multi-project workflow

set -e

echo "Multi-Project Anomaly Detection Quick Start"
echo "=============================================="
echo ""

# List available projects
echo "Available projects:"
for project_dir in configs/*/; do
    project_name=$(basename "$project_dir")
    if [ "$project_name" != "template" ]; then
        echo "  - $project_name"
    fi
done
echo ""

# Prompt for project selection
read -p "Enter project name: " PROJECT_NAME

# Validate project exists
if [ ! -d "configs/$PROJECT_NAME" ]; then
    echo "Error: Project '$PROJECT_NAME' not found"
    exit 1
fi

echo ""
echo "Setting up project: $PROJECT_NAME"
echo "=================================="

# Set project
source scripts/set-project.sh "$PROJECT_NAME"

echo ""
echo "Setting up DBT environment..."

# Setup DBT
cd dbt
source setenv.sh

echo ""
echo "Project setup complete!"
echo ""
echo "Next steps:"
echo "1. Deploy DBT seeds: dbt seed"
echo "2. Run dataloader: ./scripts/docker-run.sh dataloader"
echo "3. Run alerting: ./scripts/docker-run.sh alerting"
echo ""
echo "Or manually activate this project in new shells:"
echo "  source scripts/set-project.sh $PROJECT_NAME"