#!/bin/bash
ENVIRONMENT=$(git rev-parse --abbrev-ref HEAD)

# set to dev if not main, otherwise to staging
if [ "$ENVIRONMENT" != "main" ]; then
  ENVIRONMENT="dev"
else
  ENVIRONMENT="staging"
fi


for i in "$@"; do
  case $i in
    -e=*|--environment=*)
      ENVIRONMENT="${i#*=}"
      shift # past argument=value
      ;;
    -c=*|--config=*)
      ANOMALY_DETECTION_CONFIG_NAME="${i#*=}"
      shift # past argument=value
      ;;
    -as=*|--allowed_size=*)
      ALLOWED_SIZE="${i#*=}"
      shift # past argument=value
      ;;
    -dl=*|--delta_load=*)
      DELTA_LOAD="${i#*=}"
      shift # past argument=value
      ;;
    -from=*|--forecast_timestamp_from=*)
      FORECAST_TIMESTAMP_FROM="${i#*=}"
      shift # past argument=value
      ;;
    -*|--*)
      echo "Unknown option $i"
      exit 1
      ;;
    *)
      ;;
  esac
done

# set the above environment variables to the default from the .env file if not provided
if [ -z "$ANOMALY_DETECTION_CONFIG_NAME" ]; then
  ANOMALY_DETECTION_CONFIG_NAME=$(grep ANOMALY_DETECTION_CONFIG_NAME .env | cut -d '=' -f2)
fi

if [ -z "$ALLOWED_SIZE" ]; then
  ALLOWED_SIZE=$(grep ALLOWED_SIZE .env | cut -d '=' -f2)
fi

if [ -z "$DELTA_LOAD" ]; then
  DELTA_LOAD=$(grep DELTA_LOAD .env | cut -d '=' -f2)
fi

if [ -z "$FORECAST_TIMESTAMP_FROM" ]; then
  FORECAST_TIMESTAMP_FROM=$(grep FORECAST_TIMESTAMP_FROM .env | cut -d '=' -f2)
fi

sudo docker run -it \
    --rm \
    -v ~/.config/gcloud:/root/.config/gcloud \
    -v $(pwd)/config_$ENVIRONMENT.yaml:/project/config_$ENVIRONMENT.yaml \
    anomaly_forecast \
    --environment $ENVIRONMENT \
    --anomaly_detection_config_name $ANOMALY_DETECTION_CONFIG_NAME \
    --allowed_size $ALLOWED_SIZE \
    --delta_load $DELTA_LOAD \
    --forecast_timestamp_from "$FORECAST_TIMESTAMP_FROM"