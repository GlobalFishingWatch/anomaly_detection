suppressMessages({
  library(magrittr)
  library(data.table)
  library(purrr)
  library(dplyr)
  library(dbplyr)
  library(glue)
})

bigrquery::bq_auth(path = "/project/sa_api_key.json")
con = DBI::dbConnect(drv = bigrquery::bigquery(), project = "world-fishing-827", use_legacy_sql = FALSE)


target_table_actuals = "scratch_christian_homberg_ttl120d.anomaly_detection_actuals"
target_table_forecasts = "scratch_christian_homberg_ttl120d.anomaly_detection_forecasts"

anomaly_detection_config = yaml::read_yaml("/mnt/encrypted_data/git/data-testing/anomaly_detection/config.yaml")

config_fields = c(
  "source_dataset",
  "source_table",
  "source_date_column",
  "source_date_column_sql",
  "source_forecast_column",
  "source_forecast_column_sql",
  "source_sql"
)

current_anomaly_detection_config = anomaly_detection_config$anomalies[[1]]

# replace config fields by empty string if they don't exist, otherwise SQL string would be NULL
current_anomaly_detection_config[config_fields] = config_fields %>% 
  set_names() %>% 
  imap(~ current_anomaly_detection_config[[.x]] %||% "")

missing_dates = "date"

delta_load = F
delta_load

if (delta_load) {
  existing_dates = "SELECT DISTINCT date FROM target_table"  
} else {
  existing_dates = "'1979-01-01'"
}

maximum_valid_to = "9999-12-31 23:59:59 UTC"

create_scd_statement = function(
    select_date_value_sql,
    current_anomaly_detection_config,
    target_table,
    forecast_column_sql = "",
    maximum_valid_to = "9999-12-31 23:59:59 UTC"
) {
  current_timestamp = Sys.time() %>% strftime(tz = "UTC", usetz = T)
  glue(.null = "", "
MERGE INTO `{target_table}` AS target_table
USING (
  WITH target_table AS (SELECT * FROM `{target_table}`),
  new_actuals AS (
    SELECT 
        '{current_anomaly_detection_config$source_dataset}' source_dataset, 
        '{current_anomaly_detection_config$source_table}' source_table,
        '{current_anomaly_detection_config$source_date_column}' source_date_column,
        '{current_anomaly_detection_config$source_date_column_sql}' source_date_column_sql,
        '{current_anomaly_detection_config$source_forecast_column}' source_forecast_column,
        '{current_anomaly_detection_config$source_forecast_column_sql}' source_forecast_column_sql,
        '{current_anomaly_detection_config$source_sql}' source_sql,
     {select_date_value_sql}
    ),
  new_actuals_with_key AS (
    SELECT 
      MD5(CONCAT(
        source_dataset,
        source_table,
        source_date_column,
        source_date_column_sql,
        source_forecast_column,
        source_forecast_column_sql,
        source_sql,
        {forecast_column_sql}
        date)) key,
      * 
    FROM new_actuals
  )
  SELECT key upsert_key, * FROM new_actuals_with_key
  UNION ALL
  SELECT NULL upsert_key, new_actuals_with_key.* FROM new_actuals_with_key 
  JOIN target_table
  ON   new_actuals_with_key.key = target_table.key
  AND  new_actuals_with_key.value != target_table.value
  AND target_table.valid_to = '{maximum_valid_to}'
) delta_actuals
ON   delta_actuals.upsert_key = target_table.key
AND target_table.valid_to = '{maximum_valid_to}'
WHEN MATCHED AND delta_actuals.value != target_table.value THEN UPDATE
SET valid_to = '{current_timestamp}'
WHEN NOT MATCHED THEN
  INSERT VALUES (
    key,
    source_dataset,
    source_table,
    source_date_column,
    source_date_column_sql,
    source_forecast_column,
    source_forecast_column_sql,
    source_sql,
    {forecast_column_sql}
    date,
    value,
    '{current_timestamp}',
    '{maximum_valid_to}'
  )
")
}

select_date_value_sql = glue(.null = "", "
{current_anomaly_detection_config$source_date_column_sql} date, 
  {current_anomaly_detection_config$source_forecast_column_sql} value
FROM {current_anomaly_detection_config$source_dataset}.{current_anomaly_detection_config$source_table}
WHERE {current_anomaly_detection_config$source_date_column_sql} BETWEEN '2012-01-01' AND '2023-11-30'
AND {current_anomaly_detection_config$source_date_column_sql} IN ({missing_dates})
AND {current_anomaly_detection_config$source_date_column_sql} NOT IN ({existing_dates})
GROUP BY date
ORDER BY date"
)

create_scd_statement(select_date_value_sql, current_anomaly_detection_config, target_table_actuals) %>% safe_cached_query(con, verbose = T)

db_anomaly_detection_actuals = tbl(con, "scratch_christian_homberg_ttl120d.anomaly_detection_actuals")

db_anomaly_detection_actuals %>% safe_cached_query(overwrite_if_cached = T) %>% View


dt_train = db_anomaly_detection_actuals %>% 
  filter(valid_to == maximum_valid_to) %>% 
  filter(
    source_dataset == !!current_anomaly_detection_config$source_dataset &&
      source_table == !!current_anomaly_detection_config$source_table &&
      source_date_column == !!current_anomaly_detection_config$source_date_column &&
      source_date_column_sql == !!current_anomaly_detection_config$source_date_column_sql &&
      source_forecast_column == !!current_anomaly_detection_config$source_forecast_column &&
      source_forecast_column_sql == !!current_anomaly_detection_config$source_forecast_column_sql &&
      source_sql == !!current_anomaly_detection_config$source_sql
  ) %>% 
  filter(date != '1979-01-01') %>% 
  collect() %>% 
  select(date, y = value) %>% 
  setDT() %>% 
  .[order(date)]


dates_to_forecast = seq(as.Date("2023-01-01"), as.Date("2023-11-30"), "day")

dt_forecasts = dates_to_forecast %>% 
  map_dfr(\(current_fc_day) {
    dt_current_train = dt_train[date < current_fc_day]
    current_anomaly_detection_config$algorithms %>% 
      map_dfr(\(current_algorithm_config) {
        if (names(current_algorithm_config) == "mstl") {
          fc = dt_current_train[, y] %>% 
            forecast::msts(current_algorithm_config$parameters$season_length) %>% 
            forecast::mstl() %>% 
            predict(h = current_algorithm_config$forecast_periods) %>% 
            .[["mean"]] %>% 
            as.numeric()
        } else if (names(current_algorithm_config) == "mean") {
          mean_x_last_days = current_algorithm_config$sliding_window
          fc = dt_current_train %>% data.table::last(mean_x_last_days) %>% .[, y] %>% mean
        } else {
          return()
        }
        data.table(date = current_fc_day, fc = fc, fc_method = current_fc_method)
      })
  })

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
create_scd_statement(forecast_values_sql_string, current_anomaly_detection_config, target_table_forecasts, forecast_column_sql = "forecast_method,") %>% safe_cached_query(con, verbose = T)
