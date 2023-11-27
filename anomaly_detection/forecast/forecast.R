Sys.setenv(TABLE_FQN = "pipe_ais_v3_alpha_published.stats_daily")
Sys.setenv(FC_COLUMN = "raw_positions")
Sys.setenv(FC_METHODS = "mstl,mean_30")

table_fqn = Sys.getenv("TABLE_FQN")
fc_column = Sys.getenv("FC_COLUMN")
fc_methods = strsplit(Sys.getenv("FC_METHODS"), ",")[[1]]

suppressMessages({
  library(magrittr)
  library(data.table)
  library(purrr)
  library(dplyr)
  library(dbplyr)
  library(glue)
})

if (rstudioapi::isAvailable()) {
  # use caching for local development
  devtools::load_all()
  sql_collect_function = partial(safe_cached_query, ...=, allowed_size = 20 * BQ_GB, verbose = T)
  print("Interactive session")
} else {
  sql_collect_function = compose(dplyr::collect, data.table)
  print("Non-interactive session")
}


bigrquery::bq_auth(path = "/project/sa_api_key.json")
con = DBI::dbConnect(drv = bigrquery::bigquery(), project = "world-fishing-827", use_legacy_sql = FALSE)


target_table_actuals = "scratch_christian_homberg_ttl120d.anomaly_detection_actuals"
target_table_forecasts = "scratch_christian_homberg_ttl120d.anomaly_detection_forecasts"

review_config = yaml::read_yaml("/mnt/encrypted_data/git/data-testing/anomaly_detection/config.yaml")

config_fields = c(
  "source_dataset",
  "source_table",
  "source_date_column",
  "source_date_column_sql",
  "source_forecast_column",
  "source_forecast_column_sql",
  "source_sql"
)

current_review_config = config_fields %>% 
  set_names() %>% 
  imap(~ review_config$anomalies[[1]][[.x]] %||% "")

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
    current_review_config,
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
        '{current_review_config$source_dataset}' source_dataset, 
        '{current_review_config$source_table}' source_table,
        '{current_review_config$source_date_column}' source_date_column,
        '{current_review_config$source_date_column_sql}' source_date_column_sql,
        '{current_review_config$source_forecast_column}' source_forecast_column,
        '{current_review_config$source_forecast_column_sql}' source_forecast_column_sql,
        '{current_review_config$source_sql}' source_sql,
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
{current_review_config$source_date_column_sql} date, 
  {current_review_config$source_forecast_column_sql} value
FROM {current_review_config$source_dataset}.{current_review_config$source_table}
WHERE {current_review_config$source_date_column_sql} BETWEEN '2023-01-01' AND '2023-02-12'
AND {current_review_config$source_date_column_sql} IN ({missing_dates})
AND {current_review_config$source_date_column_sql} NOT IN ({existing_dates})
GROUP BY date
ORDER BY date"
)

create_scd_statement(select_date_value_sql, current_review_config, target_table_actuals) %>% safe_cached_query(con, verbose = T)

db_anomaly_detection_actuals = tbl(con, "scratch_christian_homberg_ttl120d.anomaly_detection_actuals")

db_anomaly_detection_actuals %>% safe_cached_query(overwrite_if_cached = T) %>% View


dt_train = db_anomaly_detection_actuals %>% 
  filter(valid_to == maximum_valid_to) %>% 
  filter(
    source_dataset == !!current_review_config$source_dataset &&
      source_table == !!current_review_config$source_table &&
      source_date_column == !!current_review_config$source_date_column &&
      source_date_column_sql == !!current_review_config$source_date_column_sql &&
      source_forecast_column == !!current_review_config$source_forecast_column &&
      source_forecast_column_sql == !!current_review_config$source_forecast_column_sql &&
      source_sql == !!current_review_config$source_sql
  ) %>% 
  filter(date != '1979-01-01') %>% 
  collect() %>% 
  select(date, y = value) %>% 
  setDT() %>% 
  .[order(date)]

fc_methods %>% 
  walk(\(current_fc_method) {
    if (current_fc_method == "mstl") {
      fc = dt_train[, y] %>% 
        forecast::msts(c(365.25, 7)) %>% 
        forecast::mstl() %>% 
        predict(h = 1) %>% 
        .[["mean"]] %>% 
        as.numeric()
    } else if ("mean" %in% current_fc_method) {
      mean_x_last_days = current_fc_method %>% 
        gsub(pattern = "mean_(.*)", replacement = "\\1") %>% 
        as.integer()
      fc = dt_train %>% data.table::last(mean_x_last_days) %>% .[, y] %>% mean
    }
    
    select_date_value_sql = glue("
    '{current_fc_method}' AS forecast_method,
    DATE('{dt_train[, max(date)]}') AS date,
    {fc} AS value
    ")
    create_scd_statement(select_date_value_sql, current_review_config, target_table_forecasts, forecast_column_sql = "forecast_method,") %>% safe_cached_query(con, verbose = T)
  })
