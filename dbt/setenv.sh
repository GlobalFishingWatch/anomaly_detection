#!/bin/bash

# Check if project is set
if [ -z "$ANOMALY_PROJECT" ]; then
    echo "Warning: ANOMALY_PROJECT not set. Use 'source scripts/set-project.sh <project-name>' first"
    echo "Falling back to legacy behavior"
fi

BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD)

# set to dev if not main, otherwise to staging
if [ "$BRANCH_NAME" != "main" ]; then
  BRANCH_NAME="dev"
else
  BRANCH_NAME="staging"
fi

export DBT_ENVIRONMENT=$BRANCH_NAME

# Set project-specific seed paths
if [ ! -z "$ANOMALY_PROJECT" ]; then
    export DBT_PROJECT_SEEDS_DIR="configs/$ANOMALY_PROJECT/dbt_seeds"
    echo "Using project-specific seeds from: $DBT_PROJECT_SEEDS_DIR"
else
    export DBT_PROJECT_SEEDS_DIR="dbt/seeds"
    echo "Using default seeds directory: $DBT_PROJECT_SEEDS_DIR"
fi