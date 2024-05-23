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
  if (is.na(ymd(date_or_period_expression, quiet = T))) {
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
    allowed_size = NULL
) {
  source_sql_hash = digest::digest(anomaly_detection_config$source_sql, algo = "md5")
  db_anomaly_detection_actuals %>% 
    filter(valid_to == maximum_valid_to) %>% 
    filter(
      source_dataset == !!anomaly_detection_config$source_dataset &&
        source_table == !!anomaly_detection_config$source_table &&
        source_timestamp_column == !!anomaly_detection_config$source_timestamp_column &&
        source_forecast_column == !!anomaly_detection_config$source_forecast_column &&
        source_forecast_column_sql == !!anomaly_detection_config$source_forecast_column_sql &&
        source_sql_hash == source_sql_hash &&
        period_length == !!anomaly_detection_config$period_length
    ) %>% 
    filter(sql(glue::glue("source_timestamp_column_sql = '{anomaly_detection_config$source_timestamp_column_sql}'"))) %>% 
    filter(timestamp != '1979-01-01') %>% 
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
  WITH target_table AS (SELECT * FROM `{target_table}`),
  new_actuals AS (
    SELECT 
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
    '{maximum_valid_to}'
  )
")
}