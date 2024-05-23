#!/bin/bash
BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD)
export DBT_ENVIRONMENT=$BRANCH_NAME