#!/bin/bash
BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD)

# set to dev if not main, otherwise to staging
if [ "$BRANCH_NAME" != "main" ]; then
  BRANCH_NAME="dev"
else
  BRANCH_NAME="staging"
fi

export DBT_ENVIRONMENT=$BRANCH_NAME