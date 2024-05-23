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

allowed_size = 60 * (1024^3)

anomaly_detection_config$anomalies %>% names


# TODO: by default start X periods ago, e.g. 250 weeks, 100 months, 500 days
Sys.setenv(FORECAST_TIMESTAMP_FROM="2024-01-01 00:00:00")

anomaly_detection_config$anomalies %>% 
  names %>% 
  # last %>% 
  # .[-(1:5)] %>% 
  intersect("parser_errors_spire_daily") %>%
  map(\(current_anomaly_config) {
    cat(current_anomaly_config, fill = T)
    Sys.setenv(ANOMALY_DETECTION_CONFIG_NAME=current_anomaly_config)
    Sys.setenv(FORECAST_TIMESTAMP_TO=strftime(Sys.time()))
    Sys.setenv(ALLOWED_SIZE = allowed_size)
    Sys.setenv(DELTA_LOAD = F)

    source("forecast.R")
  })
