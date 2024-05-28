#!/bin/bash
BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD)

# set to dev if not in staging or prod
if [ "$BRANCH_NAME" != "staging" ] && [ "$BRANCH_NAME" != "prod" ]; then
  BRANCH_NAME="dev"
fi

export DBT_ENVIRONMENT=$BRANCH_NAME