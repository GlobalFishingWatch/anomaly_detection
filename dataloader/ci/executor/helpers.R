#' Parse date or period
#'
#' @param date_or_period_expression A string that can be parsed as a date or a period
#' @param reference_date  A reference date to subtract the period from if the input is a period
#'
#' @return
#' @export
#'
#' @examples parse_date_or_period("2021-01-01")
#' @examples parse_date_or_period("1 week")
parse_date_or_period = function(date_or_period_expression, reference_date = Sys.time()) {
  if (is.na(ymd(date_or_period_expression, quiet = T)) && 
      is.na(lubridate::ymd_hms(date_or_period_expression, quiet = T))) {
    return(reference_date - period(date_or_period_expression))
  } else {
    return(date_or_period_expression)
  }
}

#' Get anomaly detection actuals
#'
#' @param con dbi connection
#' @param db_anomaly_detection_actuals tbl containing connection to anomaly detection actuals
#' @param anomaly_detection_config list containing anomaly detection config
#' @param maximum_valid_to Valid to date for filtering SCD2 table
#' @param allowed_size Maximum allowed size for the query
#'
#' @return
#' @export
#'
#' @examples
get_anomaly_detection_actuals = function(
    con,
    db_anomaly_detection_actuals, 
    anomaly_detection_config, 
    maximum_valid_to = "9999-12-31 23:59:59 UTC",
    allowed_size = NULL,
    columns = c("timestamp", "value")
) {
  db_anomaly_detection_actuals %>% 
    filter(is_latest == TRUE) %>% 
    filter(config_name == !!anomaly_detection_config$name) %>% 
    filter(dimension_split == !!anomaly_detection_config$dimension_split) %>% 
    filter(timestamp != '1979-01-01') %>% 
    filter(!is.na(value)) %>%
    select(all_of(columns)) %>%
    safe_query(con = con, allowed_size = allowed_size, verbose = T)
}

create_scd_statement = function(
    select_timestamp_value_sql,
    current_anomaly_detection_config,
    target_table,
    forecast_column_sql = "",
    maximum_valid_to = "9999-12-31 23:59:59 UTC"
) {
  current_timestamp = Sys.time() %>% strftime(tz = "UTC", usetz = T)
  source_sql_hash = digest::digest(current_anomaly_detection_config$source_sql, algo = "md5")
  
  glue(.null = "", "
MERGE INTO `{target_table}` AS target_table
USING (
  WITH target_table AS (
    SELECT * FROM `{target_table}`
    WHERE config_name = '{current_anomaly_detection_config$name}'
    AND dimension_split = '{current_anomaly_detection_config$dimension_split}'
    AND is_latest IS TRUE),
  new_actuals AS (
    SELECT 
      '{current_anomaly_detection_config$name}' config_name,
      '{current_anomaly_detection_config$dimension_split}' dimension_split,
        '{current_anomaly_detection_config$source_project}' source_project, 
        '{current_anomaly_detection_config$source_dataset}' source_dataset, 
        '{current_anomaly_detection_config$source_table}' source_table,
        '{current_anomaly_detection_config$source_timestamp_column}' source_timestamp_column,
        '{current_anomaly_detection_config$source_timestamp_column_sql}' source_timestamp_column_sql,
        '{current_anomaly_detection_config$source_forecast_column}' source_forecast_column,
        '{current_anomaly_detection_config$source_forecast_column_sql}' source_forecast_column_sql,
        '{sql(current_anomaly_detection_config$source_sql)}' source_sql,
        '{source_sql_hash}' source_sql_hash,
        '{current_anomaly_detection_config$period_length}' period_length,
     {select_timestamp_value_sql}
    ),
  new_actuals_with_key AS (
    SELECT 
      MD5(CONCAT(
        config_name,
        dimension_split,
        dimension_split_value,
        {forecast_column_sql}
        timestamp)) key,
      * 
    FROM new_actuals
  )
  SELECT key upsert_key, * FROM new_actuals_with_key
  UNION ALL
  SELECT NULL upsert_key, new_actuals_with_key.* FROM new_actuals_with_key 
  JOIN target_table
  ON   new_actuals_with_key.key = target_table.key
  AND  new_actuals_with_key.value != target_table.value
) delta_actuals
ON   delta_actuals.upsert_key = target_table.key
WHEN MATCHED AND delta_actuals.value != target_table.value THEN UPDATE
SET valid_to = '{current_timestamp}',
is_latest = FALSE
WHEN NOT MATCHED THEN
  INSERT VALUES (
    key,
    source_project,
    source_dataset,
    source_table,
    source_timestamp_column,
    source_timestamp_column_sql,
    source_forecast_column,
    source_forecast_column_sql,
    source_sql,
    source_sql_hash,
    period_length,
    {forecast_column_sql}
    timestamp,
    value,
    '{current_timestamp}',
    '{maximum_valid_to}',
    config_name,
    dimension_split,
    CAST(dimension_split_value AS STRING),
    TRUE
  )
")
}

refresh_deltas_table = function(con, project, dataset, environment,
                                max_attempts = 5) {
  # read and interpolate "sql/t_deltas.sql" file
  sql = readr::read_file("sql/t_deltas.sql") %>%
    glue(PROJECT = project, DATASET = dataset, ENVIRONMENT = environment)

  # `t_deltas.sql` is a CREATE OR REPLACE TABLE. Every dataloader container
  # ends with this refresh, so when several jobs finish in the same window
  # BigQuery rejects all but one with "another truncation operation in
  # progress". The losers retry with a jittered linear backoff -- each
  # attempt waits long enough to outlast a typical refresh (~10-30s in
  # dev) and the jitter prevents two losers from re-colliding on the next
  # round. Other errors (auth, syntax, allowed_size) bubble up unchanged.
  for (attempt in seq_len(max_attempts)) {
    res = tryCatch(
      sql %>% safe_query(con = con, verbose = T, allowed_size = 10 * BQ_GB),
      error = function(e) e
    )
    if (!inherits(res, "error")) return(res)
    is_truncation_race = grepl(
      "truncation operation in progress",
      conditionMessage(res), fixed = TRUE
    )
    if (!is_truncation_race || attempt == max_attempts) stop(res)
    sleep_s = attempt * 10 + runif(1, 0, 10)
    log_warn(glue(
      "deltas refresh raced (attempt {attempt}/{max_attempts}); ",
      "sleeping {round(sleep_s, 1)}s before retry"
    ))
    Sys.sleep(sleep_s)
  }
}