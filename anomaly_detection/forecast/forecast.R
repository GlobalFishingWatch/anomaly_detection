# Sys.setenv(ANOMALY_DETECTION_CONFIG_NAME="pipe_nmea_parsed_hourly")
# Sys.setenv(ALLOWED_SIZE=10 * (1024 ^ 3))
# Sys.setenv(FORECAST_DATETIME_FROM='2023-11-19 00:00:00')
# Sys.setenv(FORECAST_DATETIME_TO=strftime(Sys.time()))

anomaly_detection_config_name = Sys.getenv("ANOMALY_DETECTION_CONFIG_NAME")

suppressMessages({
  library(magrittr)
  library(data.table)
  library(purrr)
  library(dplyr)
  library(dbplyr)
  library(glue)
})

# safe_query is required
source("bq_utils.R")
source("helpers.R")

allowed_size = as.numeric(Sys.getenv("ALLOWED_SIZE"))

bigrquery::bq_auth(path = "/project/sa_api_key.json")
con = DBI::dbConnect(drv = bigrquery::bigquery(), project = "world-fishing-827", use_legacy_sql = FALSE)


target_table_actuals = "world-fishing-827.tech_great_expectations.anomaly_detection_actuals_datetime"
target_table_forecasts = "world-fishing-827.tech_great_expectations.anomaly_detection_forecasts_datetime"

db_anomaly_detection_actuals = tbl(con, target_table_actuals)

anomaly_detection_config = yaml::read_yaml("config.yaml")

config_fields = c(
  "source_dataset",
  "source_table",
  "source_datetime_column",
  "source_datetime_column_sql",
  "source_forecast_column",
  "source_forecast_column_sql",
  "source_sql"
)

current_anomaly_detection_config = anomaly_detection_config$anomalies[[anomaly_detection_config_name]]

# history_start has to be either a date, datetime, or a period length to be subtracted from today
history_start = current_anomaly_detection_config$history_start %||% "2012-01-01"
if (is.na(lubridate::ymd(history_start, quiet = T))) {
  history_start = Sys.Date() - lubridate::period(history_start)
}
current_anomaly_detection_config$period_length = current_anomaly_detection_config$period_length %||% "day"

# replace config fields by empty string if they don't exist, otherwise SQL string would be NULL
current_anomaly_detection_config[config_fields] = config_fields %>% 
  set_names() %>% 
  imap(~ current_anomaly_detection_config[[.x]] %||% "")

print(current_anomaly_detection_config)

maximum_valid_to = "9999-12-31 23:59:59 UTC"

# get the existing datetimes in actuals table so we can either filter by excluding existing or including 
# missing datetimes
existing_datetimes = get_anomaly_detection_actuals(
  con,
  db_anomaly_detection_actuals, 
  current_anomaly_detection_config,
  maximum_valid_to = "9999-12-31 23:59:59 UTC",
  allowed_size = allowed_size
) %>% 
  .[, datetime]


all_historic_datetimes = seq(
  as.POSIXct(history_start, tz = "UTC"), 
  lubridate::now(tz = "UTC"), 
  current_anomaly_detection_config$period_length
)
missing_datetimes = all_historic_datetimes %>% setdiff(existing_datetimes) %>% as.POSIXct(origin="1970-01-01", tz = "UTC") 

# set date sql filters so they always evaluate to true by default
existing_datetimes_sql = "'1979-01-01 00:00:00'" # datetime is never in this dummy value
missing_datetimes_sql = current_anomaly_detection_config$source_datetime_column_sql # date is always in date

delta_load = T
delta_load

# if we're doing a delta load and there are existing dates
if (delta_load & length(existing_datetimes)) {
  # only one of the two lists is required to filter, so remove the longer one
  if (length(existing_datetimes_sql) > length(missing_datetimes)) {
    missing_datetimes_sql = paste0("'", missing_datetimes, "'", collapse = ", ")
  } else {
    existing_datetimes_sql = paste0("'", existing_datetimes, "'", collapse = ", ")
  } 
}

if (current_anomaly_detection_config$source_sql != "") {
  select_datetime_value_sql = glue(current_anomaly_detection_config$source_sql)
  print(select_datetime_value_sql)
} else {
  select_datetime_value_sql = glue(.null = "", "
    {current_anomaly_detection_config$source_datetime_column_sql} datetime, 
      {current_anomaly_detection_config$source_forecast_column_sql} value
    FROM `{current_anomaly_detection_config$source_dataset}.{current_anomaly_detection_config$source_table}`
    WHERE {current_anomaly_detection_config$source_datetime_column_sql} BETWEEN '2012-01-01' AND '2099-12-31'
    AND {current_anomaly_detection_config$source_datetime_column_sql} IN ({missing_datetimes_sql})
    AND {current_anomaly_detection_config$source_datetime_column_sql} NOT IN ({existing_datetimes_sql})
    GROUP BY datetime
    ORDER BY datetime"
  )  
}


create_scd_statement(
  select_datetime_value_sql, 
  current_anomaly_detection_config, 
  target_table_actuals
) %>% 
  safe_query(con = con, allowed_size = allowed_size, verbose = T)

dt_train = get_anomaly_detection_actuals(
  con,
  db_anomaly_detection_actuals, 
  current_anomaly_detection_config,
  maximum_valid_to = "9999-12-31 23:59:59 UTC",
  allowed_size = allowed_size
) %>% 
  .[, .(datetime, y = value)] %>% 
  .[order(datetime)]


# TODO: temporary solution
# for now always forecast the last 31 days including today
# if there is no data yet for the last few days there will also be no forecast but instead multiple 
# forecasts for the most recent date - that's why we apply unique at the end
forecast_datetime_from = as.POSIXct(Sys.getenv("FORECAST_DATETIME_FROM"), format = "%Y-%m-%d %H:%M:%S", tz = "UTC")
if (is.na(forecast_datetime_from)) forecast_datetime_from = Sys.time() - 31
forecast_datetime_to = as.POSIXct(Sys.getenv("FORECAST_DATETIME_TO"), format = "%Y-%m-%d %H:%M:%S", tz = "UTC")
if (is.na(forecast_datetime_to)) forecast_datetime_to = Sys.Date()
periods_to_forecast = seq(
  forecast_datetime_from, 
  forecast_datetime_to, 
  current_anomaly_detection_config$period_length
)

dt_forecasts = periods_to_forecast %>% 
  map_dfr(\(current_fc_period) {
    dt_current_train = dt_train[datetime < current_fc_period]
    names(current_anomaly_detection_config$algorithms) %>% 
      map_dfr(\(current_fc_method) {
        current_algorithm_config = current_anomaly_detection_config$algorithms[[current_fc_method]]
        if (current_fc_method == "mstl") {
          fc = dt_current_train[, y] %>% 
            forecast::msts(unlist(current_algorithm_config$parameters$season_length)) %>% 
            forecast::mstl() %>% 
            predict(h = current_algorithm_config$forecast_periods) %>% 
            .[["mean"]] %>% 
            as.numeric()
        } else if (current_fc_method == "mean") {
          mean_x_last_periods = current_algorithm_config$parameters$sliding_window
          fc = dt_current_train %>% data.table::last(mean_x_last_periods) %>% .[, y] %>% mean
        } else {
          return()
        }
        data.table(
          datetime = dt_current_train[, max(datetime) + lubridate::period(
            1, units = current_anomaly_detection_config$period_length)], 
          fc = fc, fc_method = current_fc_method)
      })
  }) %>% unique

forecast_methods_sql_string = paste0("'", dt_forecasts[, fc_method], "'", collapse = ", ")
date_sql_string = paste0("TIMESTAMP('", dt_forecasts[, datetime], "')", collapse = ", ")
forecast_value_sql_string = paste0(dt_forecasts[, fc], collapse = ", ")

forecast_string_sql = dt_forecasts[, glue_data(.SD, "
('{fc_method}', TIMESTAMP('{datetime}'), {fc})
")] %>% paste0(collapse = ", ")

forecast_values_sql_string = glue("
forecast_method, datetime, value 
FROM UNNEST([STRUCT<forecast_method STRING, datetime TIMESTAMP, value FLOAT64>
{forecast_string_sql}
])
")

create_scd_statement(
  forecast_values_sql_string, 
  current_anomaly_detection_config, 
  target_table_forecasts, 
  forecast_column_sql = "forecast_method,"
) %>% 
  safe_query(con = con, allowed_size = allowed_size, verbose = T)
 