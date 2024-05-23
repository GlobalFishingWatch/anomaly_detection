#!/bin/bash

# Check if the table exists and create it if it doesn't

# prepend environment to actuals table and forecasts table variables
export ACTUALS_TABLE="${ENVIRONMENT}_${ACTUALS_TABLE}"
export FORECASTS_TABLE="${ENVIRONMENT}_${FORECASTS_TABLE}"
export ACTUALS_TABLE_FQN="${DATASET_ID}.${ACTUALS_TABLE}"
export FORECASTS_TABLE_FQN="${DATASET_ID}.${FORECASTS_TABLE}"

# actuals
if bq show --format=prettyjson ${PROJECT_ID}:${DATASET_ID}.${ACTUALS_TABLE} > /dev/null 2>&1; then
  echo "Table ${ACTUALS_TABLE} already exists in dataset ${DATASET_ID}."
else
  echo "Table ${ACTUALS_TABLE} does not exist. Creating table..."
  bq mk --table --project_id=${PROJECT_ID} --dataset_id=${DATASET_ID} --schema=/project/actuals_schema.json ${DATASET_ID}.${ACTUALS_TABLE}
  echo "Table ${ACTUALS_TABLE} created."
fi

# forecasts
if bq show --format=prettyjson ${PROJECT_ID}:${DATASET_ID}.${FORECASTS_TABLE} > /dev/null 2>&1; then
  echo "Table ${FORECASTS_TABLE} already exists in dataset ${DATASET_ID}."
else
  echo "Table ${FORECASTS_TABLE} does not exist. Creating table..."
  bq mk --table --project_id=${PROJECT_ID} --dataset_id=${DATASET_ID} --schema=/project/forecasts_schema.json ${DATASET_ID}.${FORECASTS_TABLE}
  echo "Table ${FORECASTS_TABLE} created."
fi


Rscript forecast.R