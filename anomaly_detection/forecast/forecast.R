# Sys.setenv(ANOMALY_DETECTION_CONFIG_NAME="ais_sources_normalized_spire")

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

bigrquery::bq_auth(path = "/project/sa_api_key.json")
con = DBI::dbConnect(drv = bigrquery::bigquery(), project = "world-fishing-827", use_legacy_sql = FALSE)


target_table_actuals = "world-fishing-827.tech_great_expectations.anomaly_detection_actuals"
target_table_forecasts = "world-fishing-827.tech_great_expectations.anomaly_detection_forecasts"

db_anomaly_detection_actuals = tbl(con, target_table_actuals)

anomaly_detection_config = yaml::read_yaml("config.yaml")

config_fields = c(
  "source_dataset",
  "source_table",
  "source_date_column",
  "source_date_column_sql",
  "source_forecast_column",
  "source_forecast_column_sql",
  "source_sql"
)

current_anomaly_detection_config = anomaly_detection_config$anomalies[[anomaly_detection_config_name]]

# replace config fields by empty string if they don't exist, otherwise SQL string would be NULL
current_anomaly_detection_config[config_fields] = config_fields %>% 
  set_names() %>% 
  imap(~ current_anomaly_detection_config[[.x]] %||% "")

print(current_anomaly_detection_config)

maximum_valid_to = "9999-12-31 23:59:59 UTC"

# get the existing dates in actuals table so we can either filter by excluding existing or including 
# missing dates
existing_dates = get_anomaly_detection_actuals(
  con,
  db_anomaly_detection_actuals, 
  current_anomaly_detection_config,
  maximum_valid_to = "9999-12-31 23:59:59 UTC"
) %>% 
  .[, date]

all_historic_dates = seq(as.Date("2012-01-01"), Sys.Date(), "day")

missing_dates = all_historic_dates %>% setdiff(existing_dates) %>% as.Date(origin="1970-01-01")

# set date sql filters so they always evaluate to true by default
existing_dates_sql = "'1979-01-01'" # date is never in this dummy value
missing_dates_sql = "date" # date is always in date

delta_load = T
delta_load

# if we're doing a delta load and there are existing dates
if (delta_load & length(existing_dates)) {
  # only one of the two lists is required to filter, so remove the longer one
  if (length(existing_dates) > length(missing_dates)) {
    missing_dates_sql = paste0("'", missing_dates, "'", collapse = ", ")
  } else {
    existing_dates_sql = paste0("'", existing_dates, "'", collapse = ", ")
  } 
}

if (current_anomaly_detection_config$source_sql != "") {
  select_date_value_sql = glue(current_anomaly_detection_config$source_sql)
  print(select_date_value_sql)
} else {
  select_date_value_sql = glue(.null = "", "
    {current_anomaly_detection_config$source_date_column_sql} date, 
      {current_anomaly_detection_config$source_forecast_column_sql} value
    FROM {current_anomaly_detection_config$source_dataset}.{current_anomaly_detection_config$source_table}
    WHERE {current_anomaly_detection_config$source_date_column_sql} BETWEEN '2012-01-01' AND '2099-12-31'
    AND {current_anomaly_detection_config$source_date_column_sql} IN ({missing_dates_sql})
    AND {current_anomaly_detection_config$source_date_column_sql} NOT IN ({existing_dates_sql})
    GROUP BY date
    ORDER BY date"
  )  
}


create_scd_statement(
  select_date_value_sql, 
  current_anomaly_detection_config, 
  target_table_actuals
) %>% 
  safe_query(con = con, allowed_size = 20 * BQ_GB)

dt_train = get_anomaly_detection_actuals(
  con,
  db_anomaly_detection_actuals, 
  current_anomaly_detection_config,
  maximum_valid_to = "9999-12-31 23:59:59 UTC"
) %>% 
  .[, .(date, y = value)] %>% 
  .[order(date)]


# TODO: temporary solution
# for now always forecast the last 31 days including today
# if there is no data yet for the last few days there will also be no forecast but instead multiple 
# forecasts for the most recent date - that's why we apply unique at the end
forecast_date_from = as.Date(Sys.getenv("FORECAST_DATE_FROM"), format = "%Y-%m-%d")
if (is.na(forecast_date_from)) forecast_date_from = Sys.Date() - 31
forecast_date_to = as.Date(Sys.getenv("FORECAST_DATE_TO"), format = "%Y-%m-%d")
if (is.na(forecast_date_to)) forecast_date_to = Sys.Date()
dates_to_forecast = seq(forecast_date_from, forecast_date_to, "day")

dt_forecasts = dates_to_forecast %>% 
  map_dfr(\(current_fc_day) {
    dt_current_train = dt_train[date < current_fc_day]
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
          mean_x_last_days = current_algorithm_config$parameters$sliding_window
          fc = dt_current_train %>% data.table::last(mean_x_last_days) %>% .[, y] %>% mean
        } else {
          return()
        }
        data.table(date = dt_current_train[, max(date)], fc = fc, fc_method = current_fc_method)
      })
  }) %>% unique

forecast_methods_sql_string = paste0("'", dt_forecasts[, fc_method], "'", collapse = ", ")
date_sql_string = paste0("DATE('", dt_forecasts[, date], "')", collapse = ", ")
forecast_value_sql_string = paste0(dt_forecasts[, fc], collapse = ", ")

forecast_string_sql = dt_forecasts[, glue_data(.SD, "
('{fc_method}', DATE('{date}'), {fc})
")] %>% paste0(collapse = ", ")

forecast_values_sql_string = glue("
forecast_method, date, value 
FROM UNNEST([STRUCT<forecast_method STRING, date DATE, value FLOAT64>
{forecast_string_sql}
])
")

create_scd_statement(
  forecast_values_sql_string, 
  current_anomaly_detection_config, 
  target_table_forecasts, 
  forecast_column_sql = "forecast_method,"
) %>% 
  safe_query(con = con)
