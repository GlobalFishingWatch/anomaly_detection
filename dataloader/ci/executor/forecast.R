if (Sys.getenv("RUNTIME") != "docker") {
  cat("LOADING DEFAULT ENVIRONMENT VARIABLES")
  dotenv::load_dot_env()
}

anomaly_detection_config_name = Sys.getenv("ANOMALY_DETECTION_CONFIG_NAME")

suppressMessages({
  library(magrittr)
  library(data.table)
  library(purrr)
  library(dplyr)
  library(dbplyr)
  library(glue)
  library(lubridate)
})

# safe_query is required
source("bq_utils.R")
source("helpers.R")

no_cores = future::availableCores() - 2
future::plan(future::multicore(), workers = no_cores)
map_fun = partial(furrr::future_imap_dfr, .options = furrr::furrr_options(seed = T))
cat(glue("Using {no_cores} cores"))

map_fun = map_fun %>% compose(progressr::with_progress, .dir = "forward")

allowed_size = as.numeric(Sys.getenv("ALLOWED_SIZE"))

bigrquery::bq_auth(path = "/project/sa_api_key.json")
con = DBI::dbConnect(drv = bigrquery::bigquery(), project = "world-fishing-827", use_legacy_sql = FALSE)


target_table_actuals = paste0(Sys.getenv("DATASET_ID"), ".", Sys.getenv("ENVIRONMENT"), "_", Sys.getenv("ACTUALS_TABLE"))
target_table_forecasts = paste0(Sys.getenv("DATASET_ID"), ".", Sys.getenv("ENVIRONMENT"), "_", Sys.getenv("FORECASTS_TABLE"))

db_anomaly_detection_actuals = tbl(con, target_table_actuals)

anomaly_detection_config = yaml::read_yaml("config.yaml")

current_anomaly_detection_config = anomaly_detection_config$anomalies[[anomaly_detection_config_name]]
current_anomaly_detection_config$name = anomaly_detection_config_name

# history_start has to be either a date, timestamp, or a period length to be subtracted from today
history_start = current_anomaly_detection_config$history_start %||% "2012-01-01" %>% 
  parse_date_or_period()
current_anomaly_detection_config$period_length = current_anomaly_detection_config$period_length %||% "day"

config_fields = c(
  "source_dataset",
  "source_table",
  "source_timestamp_column",
  "source_timestamp_column_sql",
  "source_forecast_column",
  "source_forecast_column_sql",
  "source_sql"
)

# replace config fields by empty string if they don't exist, otherwise SQL string would be NULL
current_anomaly_detection_config[config_fields] = config_fields %>% 
  set_names() %>% 
  imap(~ current_anomaly_detection_config[[.x]] %||% "")

print(current_anomaly_detection_config)

# get the existing timestamps in actuals table so we can either filter by excluding existing or including 
# missing timestamps
existing_timestamps = get_anomaly_detection_actuals(
  con,
  db_anomaly_detection_actuals, 
  current_anomaly_detection_config,
  maximum_valid_to = "9999-12-31 23:59:59 UTC",
  allowed_size = allowed_size
) %>% 
  .[, timestamp]


all_historic_timestamps = seq(
  history_start %>% as.Date() %>% as.POSIXct() %>% with_tz("UTC"), 
  now(tz = "UTC"), 
  current_anomaly_detection_config$period_length
)

missing_timestamps = all_historic_timestamps %>% setdiff(existing_timestamps) %>% as.POSIXct(origin="1970-01-01", tz = "UTC") 

# set date sql filters so they always evaluate to true by default
existing_timestamps_sql = "'1979-01-01 00:00:00'" # timestamp is never in this dummy value
missing_timestamps_sql = current_anomaly_detection_config$source_timestamp_column_sql # date is always in date

delta_load = Sys.getenv("DELTA_LOAD") %>% as.logical()
delta_load

# if we're doing a delta load and there are existing dates
if (delta_load & length(existing_timestamps)) {
  # only one of the two lists is required to filter, so remove the longer one
  if (length(existing_timestamps) > length(missing_timestamps)) {
    missing_timestamps_sql = paste0("'", missing_timestamps, "'", collapse = ", ")
  } else {
    existing_timestamps_sql = paste0("'", existing_timestamps, "'", collapse = ", ")
  } 
}

if (current_anomaly_detection_config$source_sql != "") {
  select_timestamp_value_sql = glue(current_anomaly_detection_config$source_sql)
  print(select_timestamp_value_sql)
} else {
  select_timestamp_value_sql = glue(.null = "", "
    TIMESTAMP_TRUNC({current_anomaly_detection_config$source_timestamp_column_sql}, {current_anomaly_detection_config$period_length}) timestamp, 
      {current_anomaly_detection_config$source_forecast_column_sql} value
    FROM `{current_anomaly_detection_config$source_dataset}.{current_anomaly_detection_config$source_table}`
    WHERE {current_anomaly_detection_config$source_timestamp_column_sql} BETWEEN '2012-01-01' AND '2099-12-31'
    AND {current_anomaly_detection_config$source_timestamp_column_sql} IN ({missing_timestamps_sql})
    AND {current_anomaly_detection_config$source_timestamp_column_sql} NOT IN ({existing_timestamps_sql})
    AND {current_anomaly_detection_config$source_timestamp_column_sql} >= '{history_start}'
    GROUP BY timestamp
    ORDER BY timestamp"
  )  
}

if (length(missing_timestamps)) {
  create_scd_statement(
    select_timestamp_value_sql, 
    current_anomaly_detection_config, 
    target_table_actuals
  ) %>% 
    safe_query(con = con, allowed_size = allowed_size, verbose = T) 
} else {
  cat("No actual data missing", fill = T)
}


# FORECASTING ---------------------------------------------------------------------------------

dt_train = get_anomaly_detection_actuals(
  con,
  db_anomaly_detection_actuals, 
  current_anomaly_detection_config,
  maximum_valid_to = "9999-12-31 23:59:59 UTC",
  allowed_size = allowed_size
) %>% 
  .[, .(timestamp, y = value)] %>% 
  .[order(timestamp)]

# By default forecast the last 90 days, unless this is provided by the config or environment
if (Sys.getenv("FORECAST_TIMESTAMP_FROM") != "") {
  forecast_timestamp_from = as.POSIXct(Sys.getenv("FORECAST_TIMESTAMP_FROM"), format = "%Y-%m-%d %H:%M:%S", tz = "UTC")
} else {
  forecast_timestamp_from = current_anomaly_detection_config$forecast_start %||% "90 days" %>% 
    parse_date_or_period()  %>% 
    with_tz("UTC") %>% 
    floor_date(current_anomaly_detection_config$period_length)
}


forecast_timestamp_to = as.POSIXct(Sys.getenv("FORECAST_TIMESTAMP_TO"), format = "%Y-%m-%d %H:%M:%S") %>% 
  with_tz("UTC")
if (is.na(forecast_timestamp_to)) forecast_timestamp_to = Sys.time() %>% with_tz("UTC")
periods_to_forecast = seq(
  forecast_timestamp_from, 
  forecast_timestamp_to, 
  current_anomaly_detection_config$period_length
)

# if there is no data yet for the last few days there will also be no forecast but instead multiple 
# forecasts for the most recent date - that's why we apply unique at the end
generate_forecasts = function(periods_to_forecast) {
  p = progressr::progressor(steps = length(periods_to_forecast))
  
  periods_to_forecast %>% 
    furrr::future_imap_dfr(\(current_fc_period, index) {
      # cat(glue("forecasting {index} / {length(periods_to_forecast)}: {current_fc_period}"), fill = T)
      p()
      dt_current_train = dt_train[timestamp < current_fc_period]
      if (dt_current_train[, .N] < 15) return(data.table(timestamp = NA, fc = NA, fc_method = NA))
      names(current_anomaly_detection_config$algorithms) %>% 
        map_dfr(\(current_fc_method) {
          current_algorithm_config = current_anomaly_detection_config$algorithms[[current_fc_method]]
          current_thresholds = current_algorithm_config$thresholds %||% list(low = .02, high = .2)
          if (current_fc_method == "mstl") {
            fc = dt_current_train[, y] %>% 
              forecast::msts(unlist(current_algorithm_config$parameters$season_length)) %>% 
              forecast::mstl() %>% 
              predict(h = 1) %>% 
              .[["mean"]] %>% 
              as.numeric()
          } else if (current_fc_method == "mean") {
            mean_x_last_periods = current_algorithm_config$parameters$sliding_window
            fc = dt_current_train %>% data.table::last(mean_x_last_periods) %>% .[, y] %>% mean
          } else if (current_fc_method == "median") {
            median_x_last_periods = current_algorithm_config$parameters$sliding_window
            fc = dt_current_train %>% data.table::last(median_x_last_periods) %>% .[, y] %>% median
          } else {
            return()
          }
          
          # set fc value to the lowest previously seen value if it's negative
          fc = max(dt_current_train[, min(y)], fc)
          
          data.table(
            timestamp = current_fc_period, 
            fc = fc,
            fc_method = current_fc_method,
            low_confidence = current_thresholds$low,
            high_confidence = current_thresholds$high
          )
        })
    }) %>% 
    .[!is.na(timestamp)] %>% 
    .[order(timestamp, fc_method)] %>% 
    unique
}

dt_forecasts = progressr::with_progress(generate_forecasts(periods_to_forecast), enable = T)

forecast_methods_sql_string = paste0("'", dt_forecasts[, fc_method], "'", collapse = ", ")
date_sql_string = paste0("TIMESTAMP('", dt_forecasts[, timestamp], "')", collapse = ", ")
forecast_value_sql_string = paste0(dt_forecasts[, fc], collapse = ", ")

forecast_string_sql = dt_forecasts[, glue_data(.SD, "
('{fc_method}', {low_confidence}, {high_confidence}, TIMESTAMP('{timestamp}'), {fc})
")] %>% paste0(collapse = ", ")

forecast_values_sql_string = glue("
forecast_method, timestamp, value, low_confidence, high_confidence
FROM UNNEST([STRUCT<
  forecast_method STRING, 
  low_confidence FLOAT64, 
  high_confidence FLOAT64, 
  timestamp TIMESTAMP, 
  value FLOAT64>
{forecast_string_sql}
])
")

create_scd_statement(
  forecast_values_sql_string, 
  current_anomaly_detection_config, 
  target_table_forecasts, 
  forecast_column_sql = "forecast_method, low_confidence, high_confidence,"
) %>% 
  safe_query(con = con, allowed_size = allowed_size, verbose = T)
