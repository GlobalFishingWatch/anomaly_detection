#!/bin/bash

# Project Switcher for Anomaly Detection System
# Usage: source scripts/set-project.sh <project-name>

if [ $# -eq 0 ]; then
    echo "Usage: source scripts/set-project.sh <project-name>"
    echo ""
    echo "Available projects:"
    for project_dir in configs/*/; do
        project_name=$(basename "$project_dir")
        if [ "$project_name" != "template" ]; then
            echo "  - $project_name"
        fi
    done
    return 1
fi

PROJECT_NAME="$1"
PROJECT_CONFIG_DIR="configs/$PROJECT_NAME"

# Check if project exists
if [ ! -d "$PROJECT_CONFIG_DIR" ]; then
    echo "Error: Project '$PROJECT_NAME' not found in configs/"
    echo "Available projects:"
    for project_dir in configs/*/; do
        project_name=$(basename "$project_dir")
        if [ "$project_name" != "template" ]; then
            echo "  - $project_name"
        fi
    done
    return 1
fi

# Set environment variables
export ANOMALY_PROJECT="$PROJECT_NAME"
export ANOMALY_PROJECT_CONFIG_DIR="$PROJECT_CONFIG_DIR"

# Set project-specific terraform variables if they exist
if [ -f "$PROJECT_CONFIG_DIR/terraform.tfvars" ]; then
    export TF_VAR_FILE="$(pwd)/$PROJECT_CONFIG_DIR/terraform.tfvars"
fi

echo "Switched to project: $PROJECT_NAME"
echo "Project config directory: $PROJECT_CONFIG_DIR"
echo "Environment variables set:"
echo "  ANOMALY_PROJECT=$ANOMALY_PROJECT"
echo "  ANOMALY_PROJECT_CONFIG_DIR=$ANOMALY_PROJECT_CONFIG_DIR"
if [ ! -z "$TF_VAR_FILE" ]; then
    echo "  TF_VAR_FILE=$TF_VAR_FILE"
fi