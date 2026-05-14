suppressMessages({
  library(magrittr)
  library(data.table)
  library(purrr)
  library(dplyr)
  library(dbplyr)
  library(glue)
  library(lubridate)
  library(optparse)
  library(logger)
})

log_threshold(INFO)

source("bq_utils.R")
source("helpers.R")

option_list = list(
  make_option(c("-e", "--environment"), type = "character", default = NULL, 
              help = "Environment"),
  make_option(c("-c", "--anomaly_detection_config_name"), type = "character", default = NULL,
              help = "Anomaly detection config name"),
  make_option(c("-p", "--project_id"), type = "character", default = "world-fishing-827",
              help = "Project ID"),
  make_option(c("-d", "--dataset_id"), type = "character", default = "tech_anomaly_detection",
              help = "Dataset ID"),
  make_option(c("-a", "--actuals_table"), type = "character", default = "actuals",
              help = "Actuals table"),
  make_option(c("-f", "--forecasts_table"), type = "character", default = "forecasts",
              help = "Forecasts table"),
  make_option(c("-l", "--delta_load"), type = "character", default = "T",
              help = "Delta load"),
  make_option(c("-s", "--allowed_size"), type = "character", default = "60",
              help = "Allowed size"),
  make_option(c("-t", "--forecast_timestamp_from"), type = "character", default = "",
              help = "Forecast timestamp from"),
  make_option(c("-u", "--forecast_timestamp_to"), type = "character", default = "",
              help = "Forecast timestamp to")
)

parser = OptionParser(option_list = option_list)
args = parse_args(parser)

log_info("Parsed arguments:")
log_info(list(args))

anomaly_detection_config_name = args$anomaly_detection_config_name
allowed_size = as.numeric(args$allowed_size) * BQ_GB
delta_load = as.logical(args$delta_load)
environment = args$environment
project_id = args$project_id
dataset_id = args$dataset_id
actuals_table = args$actuals_table
forecasts_table = args$forecasts_table
forecast_timestamp_from = args$forecast_timestamp_from
forecast_timestamp_to = args$forecast_timestamp_to

no_cores = future::availableCores() - 2
future::plan(future::multicore(), workers = no_cores)
map_fun = partial(furrr::future_imap_dfr, .options = furrr::furrr_options(seed = T))
log_info(glue("Using {no_cores} cores"))

map_fun = map_fun %>% compose(progressr::with_progress, .dir = "forward")

con = DBI::dbConnect(drv = bigrquery::bigquery(), project = "world-fishing-827", use_legacy_sql = FALSE)

target_table_actuals = paste0(dataset_id, ".t_", environment, "_", actuals_table)
target_table_forecasts = paste0(dataset_id, ".t_", environment, "_", forecasts_table)

db_anomaly_detection_actuals = tbl(con, target_table_actuals)

anomaly_detection_config = yaml::read_yaml(glue('config_{environment}.yaml'))

current_anomaly_detection_config = anomaly_detection_config$anomalies[[anomaly_detection_config_name]]
current_anomaly_detection_config$name = anomaly_detection_config_name

# history_start has to be either a date, timestamp, or a period length to be subtracted from today
history_start = current_anomaly_detection_config$history_start %||% "2012-01-01" %>% 
  parse_date_or_period()
current_anomaly_detection_config$period_length = current_anomaly_detection_config$period_length %||% "day"

# create mapping between "full" sql period lengths and R's unconventional short lengths
r_period_lengths = c("sec", "min", "hour", "day", "DSTday", "week", "month", "quarter", "year")
sql_period_lengths = c("SECOND", "MINUTE", "HOUR", "DAY", "DAY", "WEEK", "MONTH", "QUARTER", "YEAR")
period_length_mapping = r_period_lengths %>% 
  set_names(sql_period_lengths)

if (!tolower(current_anomaly_detection_config$period_length) %in% tolower(sql_period_lengths)) {
  stop(glue("period_length {current_anomaly_detection_config$period_length} is not supported"))
}

config_fields = c(
  "dimension_split",
  "source_project",
  "source_dataset",
  "source_table",
  "source_timestamp_column",
  "source_timestamp_column_sql",
  "source_forecast_column",
  "source_forecast_column_sql",
  "source_sql",
  "source_filter_sql"
)

# replace config fields by empty string if they don't exist, otherwise SQL string would be NULL
current_anomaly_detection_config[config_fields] = config_fields %>% 
  set_names() %>% 
  imap(~ current_anomaly_detection_config[[.x]] %||% "")

log_info("Current anomaly detection config:")
# Escape braces so logger's glue formatter does not try to resolve
# {placeholder} tokens embedded in source_sql before they are substituted
# at line ~161 (e.g. {missing_timestamps_sql} is only defined below).
cfg_text = paste(capture.output(str(current_anomaly_detection_config)), collapse = "\n")
log_info(gsub("\\}", "}}", gsub("\\{", "{{", cfg_text)))

if ("allowed_size" %in% names(current_anomaly_detection_config)) {
  allowed_size = as.numeric(current_anomaly_detection_config$allowed_size) * BQ_GB
}

# get the existing timestamps in actuals table so we can either filter by excluding existing or including 
# missing timestamps
existing_timestamps = get_anomaly_detection_actuals(
  con,
  db_anomaly_detection_actuals, 
  current_anomaly_detection_config,
  maximum_valid_to = "9999-12-31 23:59:59 UTC",
  allowed_size = allowed_size,
  columns = c("timestamp")
) %>% 
  .[, timestamp]


all_historic_timestamps = seq(
  history_start %>% as.Date() %>% as.POSIXct() %>% with_tz("UTC"), 
  now(tz = "UTC"), 
  period_length_mapping[toupper(current_anomaly_detection_config$period_length)]
)

missing_timestamps = all_historic_timestamps %>% setdiff(existing_timestamps) %>% as.POSIXct(origin="1970-01-01", tz = "UTC") 

# set date sql filters so they always evaluate to true by default
existing_timestamps_sql = "'1979-01-01 00:00:00'" # timestamp is never in this dummy value
missing_timestamps_sql = current_anomaly_detection_config$source_timestamp_column_sql # date is always in date

# if we're doing a delta load and there are existing dates
if (delta_load & length(existing_timestamps)) {
  # only one of the two lists is required to filter, so remove the longer one
  if (length(existing_timestamps) > length(missing_timestamps)) {
    missing_timestamps_sql = paste0("'", missing_timestamps, "'", collapse = ", ")
  } else {
    existing_timestamps_sql = paste0("'", existing_timestamps, "'", collapse = ", ")
  } 
}

dimension_split_select = if(current_anomaly_detection_config$dimension_split == "") {
  "''"
  } else {current_anomaly_detection_config$dimension_split}

source_filter_sql = if(current_anomaly_detection_config$source_filter_sql == "") {
  ""
  } else {glue("AND {current_anomaly_detection_config$source_filter_sql}")}

if (current_anomaly_detection_config$source_sql != "") {
  select_timestamp_value_sql = glue(current_anomaly_detection_config$source_sql)
  log_info(select_timestamp_value_sql)
} else {
  select_timestamp_value_sql = glue(.null = "", "
    TIMESTAMP_TRUNC({current_anomaly_detection_config$source_timestamp_column_sql}, {current_anomaly_detection_config$period_length}) timestamp,
      {current_anomaly_detection_config$source_forecast_column_sql} value, {dimension_split_select} dimension_split_value
    FROM `{current_anomaly_detection_config$source_project}.{current_anomaly_detection_config$source_dataset}.{current_anomaly_detection_config$source_table}`
    WHERE {current_anomaly_detection_config$source_timestamp_column_sql} BETWEEN '2012-01-01' AND '2099-12-31'
    AND {current_anomaly_detection_config$source_timestamp_column_sql} IN ({missing_timestamps_sql})
    AND {current_anomaly_detection_config$source_timestamp_column_sql} NOT IN ({existing_timestamps_sql})
    AND {current_anomaly_detection_config$source_timestamp_column_sql} >= '{history_start}'
    {source_filter_sql}
    GROUP BY timestamp, dimension_split_value
    ORDER BY timestamp, dimension_split_value"
  )
}

# Gap-fill the actuals MERGE with value=0 for every (missing_timestamp, dim)
# pair that the source query does not return a row for. Without this, a feed
# that stops publishing (e.g. marinetraffic on 2026-01-01, ais-listener on
# 2026-05-04) leaves the actuals table with a hole, the forecast model never
# trains on the post-death zeros, and the alert keeps firing forever
# (forecast stuck at the pre-death level, actual coalesced to 0 in t_deltas).
# We restrict the gap-fill grid to dims with at least one actuals row in the
# last 180 days so truly-retired dims aren't resurrected.
KNOWN_DIMS_LOOKBACK_DAYS = 180
known_dims = get_known_dims_recent(
  con,
  db_anomaly_detection_actuals,
  current_anomaly_detection_config,
  lookback_days = KNOWN_DIMS_LOOKBACK_DAYS,
  allowed_size = allowed_size
)

if (length(missing_timestamps) > 0 && length(known_dims) > 0) {
  missing_ts_sql = paste0(
    "TIMESTAMP '",
    format(missing_timestamps, "%Y-%m-%d %H:%M:%S"),
    "'", collapse = ", "
  )
  # BigQuery SQL-quote: single-quote literals with doubled single quotes for
  # any embedded apostrophes (e.g. dim values like "o'reilly").
  known_dims_sql = paste0(
    "'", gsub("'", "''", known_dims, fixed = TRUE), "'", collapse = ", "
  )
  # The actuals SCD2 stores `dimension_split_value` as STRING (see the CAST
  # in `create_scd_statement`), so our gap grid produces STRING values. But
  # source views may type the dim column as BOOL or NUMERIC (e.g.
  # `v_world_fishing_827_queries_billed_by_sa_non_sa` whose dim is a BOOL
  # `service_account`). USING(dimension_split_value) on a STRING-vs-BOOL
  # pair errors with "incompatible types"; we cast the raw side to STRING
  # to mirror the SCD2 storage type.
  select_timestamp_value_sql = glue(.null = "", "
    expected.timestamp timestamp,
    IFNULL(raw.value, 0) value,
    expected.dimension_split_value dimension_split_value
  FROM (
    SELECT ts AS timestamp, dim AS dimension_split_value
    FROM UNNEST([{missing_ts_sql}]) ts
    CROSS JOIN UNNEST([{known_dims_sql}]) dim
  ) expected
  LEFT JOIN (
    SELECT
      timestamp,
      value,
      CAST(dimension_split_value AS STRING) AS dimension_split_value
    FROM ( SELECT {select_timestamp_value_sql} )
  ) raw USING(timestamp, dimension_split_value)
  ")
  log_info(glue(
    "gap-filling actuals: {length(known_dims)} known dims x ",
    "{length(missing_timestamps)} missing timestamps ",
    "(lookback={KNOWN_DIMS_LOOKBACK_DAYS}d)"
  ))
}

if (length(missing_timestamps)) {
  create_scd_statement(
    select_timestamp_value_sql, 
    current_anomaly_detection_config, 
    target_table_actuals
  ) %>% 
    safe_query(con = con, allowed_size = allowed_size, verbose = T) 
} else {
  log_info("No actual data missing", fill = T)
}


# FORECASTING ---------------------------------------------------------------------------------

dt_train = get_anomaly_detection_actuals(
  con,
  db_anomaly_detection_actuals, 
  current_anomaly_detection_config,
  maximum_valid_to = "9999-12-31 23:59:59 UTC",
  allowed_size = allowed_size,
  columns = c("timestamp", "value", "dimension_split_value")
) %>% 
  .[, .(timestamp, y = value, dimension_split_value)] %>% 
  .[dimension_split_value %>% is.na, dimension_split_value := "NA"] %>% 
  .[order(timestamp, dimension_split_value)]

if (!dt_train[, .N]) {
  log_error("No training data available, nothing to forecast", fill = T)
  quit(status = 0)
}


# By default forecast the last 90 periods, unless this is provided by the config or environment
if (forecast_timestamp_from == "") {
  forecast_timestamp_from = current_anomaly_detection_config$forecast_start %||% 
  glue("90 {current_anomaly_detection_config$period_length}s")
}

forecast_timestamp_from %<>% 
    parse_date_or_period()  %>% 
    max(as.POSIXct(history_start)) %>%
    with_tz("UTC") %>% 
    floor_date(current_anomaly_detection_config$period_length)

log_info(glue("Forecasting from {forecast_timestamp_from}"), fill = T)

forecast_timestamp_to = as.POSIXct(forecast_timestamp_to, format = "%Y-%m-%d %H:%M:%S") %>% 
  with_tz("UTC")
if (is.na(forecast_timestamp_to)) forecast_timestamp_to = Sys.time() %>% with_tz("UTC")
periods_to_forecast = seq(
  forecast_timestamp_from, 
  forecast_timestamp_to, 
  current_anomaly_detection_config$period_length
)

statistical_methods = c("mean", "median", "max", "min", "sum")

# if there is no data yet for the last few days there will also be no forecast but instead multiple 
# forecasts for the most recent date - that's why we apply unique at the end
generate_forecasts = function(periods_to_forecast, current_dimension_split_value) {
  p = progressr::progressor(steps = length(periods_to_forecast))
  
  dt_current_dimension_split = dt_train[dimension_split_value == current_dimension_split_value]
  log_info(glue("forecasting {dt_current_dimension_split[1, dimension_split_value]}"), fill = T)
  
  dt_current_forecasts = periods_to_forecast %>% 
    furrr::future_imap_dfr(\(current_fc_period, index) {
      # cat(glue("forecasting {index} / {length(periods_to_forecast)}: {current_fc_period}"), fill = T)
      p()
      dt_current_train = dt_current_dimension_split[timestamp < current_fc_period]
      names(current_anomaly_detection_config$algorithms) %>% 
        map_dfr(\(current_fc_method) {
          current_algorithm_config = current_anomaly_detection_config$algorithms[[current_fc_method]]
          if (current_fc_method == "mstl") {
            if (dt_current_train[, .N] < 2 * current_algorithm_config$parameters$season_length[[1]]) return(data.table(dimension_split_value = NA, timestamp = NA, fc = NA, fc_method = NA))
            fc = dt_current_train[, y] %>% 
              forecast::msts(unlist(current_algorithm_config$parameters$season_length)) %>% 
              forecast::mstl() %>% 
              predict(h = 1) %>% 
              .[["mean"]] %>% 
              as.numeric()
          } else if (current_fc_method %in% statistical_methods) {
            x_last_periods = current_algorithm_config$parameters$sliding_window
            if (dt_current_train[, .N] < x_last_periods) return(data.table(dimension_split_value = NA, timestamp = NA, fc = NA, fc_method = NA))
            fc = get(current_fc_method)(dt_current_train %>% data.table::last(x_last_periods) %>% .[, y])
          } else if (current_fc_method == "constant_value") {
            fc = current_algorithm_config$parameters$value
          } else {
            return()
          }
          
          if (fc < 0 && "replace_negative_forecasts_by" %in% current_algorithm_config$parameters) {
            if (current_algorithm_config$parameters$replace_negative_forecasts_by == "zero") {
              fc = 0
            } else if (current_algorithm_config$parameters$replace_negative_forecasts_by %in% statistical_methods) {
              fc = dt_current_train[, get(current_algorithm_config$parameters$replace_negative_forecasts_by)(y)]
            }
          }
          
          
          data.table(
            dimension_split_value = current_dimension_split_value,
            timestamp = current_fc_period, 
            fc = fc,
            fc_method = current_fc_method
          )
        })
    }) %>% 
    .[!is.na(timestamp)] %>% 
    .[order(timestamp, fc_method)] %>% 
    unique
  
  if (dt_current_forecasts[, .N]) return(dt_current_forecasts) else return()
}

dt_forecasts = dt_train[, dimension_split_value %>% unique %>% sort] %>% 
  map_dfr(\(current_dimension_split_value) {
    progressr::with_progress(generate_forecasts(periods_to_forecast, current_dimension_split_value), enable = T)
  })


forecast_string_sql = dt_forecasts[, glue_data(.SD, "
('{dimension_split_value}', '{fc_method}', TIMESTAMP('{timestamp}'), {fc})
")] %>% paste0(collapse = ", ")

forecast_values_sql_string = glue("
dimension_split_value, forecast_method, timestamp, value
FROM UNNEST([STRUCT<
  dimension_split_value STRING,
  forecast_method STRING, 
  timestamp TIMESTAMP, 
  value FLOAT64>
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


refresh_deltas_table(con, project_id, dataset_id, environment)