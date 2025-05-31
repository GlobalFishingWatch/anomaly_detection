#!/bin/bash

# Project-aware Docker runner for anomaly detection
# Usage: ./scripts/docker-run.sh <component> [additional-args]

COMPONENT="$1"
shift  # Remove first argument, pass rest to docker

if [ -z "$COMPONENT" ]; then
    echo "Usage: ./scripts/docker-run.sh <component> [additional-args]"
    echo "Components: dataloader, alerting"
    exit 1
fi

if [ -z "$ANOMALY_PROJECT" ]; then
    echo "Error: ANOMALY_PROJECT not set. Use 'source scripts/set-project.sh <project-name>' first"
    exit 1
fi

# Set component-specific paths
case "$COMPONENT" in
    "dataloader")
        DOCKER_DIR="dataloader/ci/executor"
        CONFIG_FILE="configs/$ANOMALY_PROJECT/dataloader/config_demo.yaml"
        ;;
    "alerting")
        DOCKER_DIR="alerting/ci/executor"
        CONFIG_FILE="configs/$ANOMALY_PROJECT/alerting/config.yaml"
        ;;
    *)
        echo "Error: Unknown component '$COMPONENT'"
        echo "Available components: dataloader, alerting"
        exit 1
        ;;
esac

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file not found: $CONFIG_FILE"
    echo "Make sure your project has the required configuration files"
    exit 1
fi

# Get project-specific terraform variables
if [ -f "configs/$ANOMALY_PROJECT/terraform.tfvars" ]; then
    GCP_PROJECT_ID=$(grep '^project' "configs/$ANOMALY_PROJECT/terraform.tfvars" | cut -d'"' -f2)
else
    echo "Warning: terraform.tfvars not found for project $ANOMALY_PROJECT"
    GCP_PROJECT_ID="$ANOMALY_PROJECT"
fi

echo "Running $COMPONENT for project: $ANOMALY_PROJECT"
echo "Config file: $CONFIG_FILE"
echo "GCP Project: $GCP_PROJECT_ID"

# Run Docker with project-specific environment
cd "$DOCKER_DIR"
docker run --rm \
    -v ~/.config/gcloud:/root/.config/gcloud \
    -v "$(pwd)/../../..":"$(pwd)/../../.." \
    -w "$(pwd)" \
    -e GCP_PROJECT_ID="$GCP_PROJECT_ID" \
    -e BQ_DATASET="tech_anomaly_detection" \
    -e CONFIG_PATH="$(basename "$CONFIG_FILE")" \
    -e ANOMALY_PROJECT="$ANOMALY_PROJECT" \
    anomaly-${COMPONENT}-demo "$@"