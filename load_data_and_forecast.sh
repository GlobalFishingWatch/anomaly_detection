#!/bin/bash
ENVIRONMENT=$(git rev-parse --abbrev-ref HEAD)

# set to dev if not in staging or prod
if [ "$ENVIRONMENT" != "staging" ] && [ "$ENVIRONMENT" != "prod" ]; then
  ENVIRONMENT="dev"
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


sudo docker run -it --env-file .env \
    -e ENVIRONMENT=$ENVIRONMENT \
    -e ANOMALY_DETECTION_CONFIG_NAME=$ANOMALY_DETECTION_CONFIG_NAME \
    -e ALLOWED_SIZE=$ALLOWED_SIZE \
    -e DELTA_LOAD=$DELTA_LOAD \
    -e FORECAST_TIMESTAMP_FROM="$FORECAST_TIMESTAMP_FROM" \
    --rm \
    -v ~/.config/gcloud:/root/.config/gcloud \
    -v $(pwd)/config_$ENVIRONMENT.yaml:/project/config.yaml \
    anomaly_forecast