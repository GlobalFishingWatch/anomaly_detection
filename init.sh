#!/bin/bash

# Check if the table exists and create it if it doesn't

# prepend environment to actuals table and forecasts table variables
export ACTUALS_TABLE_ENV="${ENVIRONMENT}_${ACTUALS_TABLE}"
export FORECASTS_TABLE_ENV="${ENVIRONMENT}_${FORECASTS_TABLE}"
export RUNTIME=docker

# actuals
if bq show --format=prettyjson ${PROJECT_ID}:${DATASET_ID}.${ACTUALS_TABLE_ENV} > /dev/null 2>&1; then
  echo "Table ${ACTUALS_TABLE_ENV} already exists in dataset ${DATASET_ID}."
else
  echo "Table ${ACTUALS_TABLE_ENV} does not exist. Creating table..."
  bq mk --table --project_id=${PROJECT_ID} --dataset_id=${DATASET_ID} --schema=/project/actuals_schema.json ${DATASET_ID}.${ACTUALS_TABLE_ENV}
  echo "Table ${ACTUALS_TABLE_ENV} created."
fi

# forecasts
if bq show --format=prettyjson ${PROJECT_ID}:${DATASET_ID}.${FORECASTS_TABLE_ENV} > /dev/null 2>&1; then
  echo "Table ${FORECASTS_TABLE_ENV} already exists in dataset ${DATASET_ID}."
else
  echo "Table ${FORECASTS_TABLE_ENV} does not exist. Creating table..."
  bq mk --table --project_id=${PROJECT_ID} --dataset_id=${DATASET_ID} --schema=/project/forecasts_schema.json ${DATASET_ID}.${FORECASTS_TABLE_ENV}
  echo "Table ${FORECASTS_TABLE_ENV} created."
fi


Rscript forecast.R