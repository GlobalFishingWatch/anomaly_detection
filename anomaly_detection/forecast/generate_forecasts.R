library(magrittr)
library(data.table)
library(ggplot2)
library(purrr)
library(glue)
library(lubridate)
library(dplyr)
library(dbplyr)

anomaly_detection_config = yaml::read_yaml("config.yaml")

anomaly_detection_config$anomalies %>% names

allowed_size = 50 * (1024^3)

anomaly_detection_config$anomalies %>% names


Sys.setenv(FORECAST_DATETIME_FROM="2023-01-01 00:00:00")

anomaly_detection_config$anomalies %>% 
  names %>% 
  last %>% 
  # .[-(1:5)] %>% 
  map(\(current_anomaly_config) {
    cat(current_anomaly_config, fill = T)
    Sys.setenv(ANOMALY_DETECTION_CONFIG_NAME=current_anomaly_config)
    # Sys.setenv(FORECAST_DATETIME_FROM='2023-10-11 00:00:00')
    Sys.setenv(FORECAST_DATETIME_TO=strftime(Sys.time()))
    Sys.setenv(ALLOWED_SIZE = allowed_size)
    # Sys.setenv(FORECAST_DATE_TO='2023-01-01')
    
    source("forecast.R")
  })
