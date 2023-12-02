get_anomaly_detection_actuals = function(
    con,
    db_anomaly_detection_actuals, 
    anomaly_detection_config, 
    maximum_valid_to = "9999-12-31 23:59:59 UTC"
) {
  source_sql_hash = digest::digest(anomaly_detection_config$source_sql, algo = "md5")
  db_anomaly_detection_actuals %>% 
    filter(valid_to == maximum_valid_to) %>% 
    filter(
      source_dataset == !!anomaly_detection_config$source_dataset &&
        source_table == !!anomaly_detection_config$source_table &&
        source_date_column == !!anomaly_detection_config$source_date_column &&
        source_date_column_sql == !!anomaly_detection_config$source_date_column_sql &&
        source_forecast_column == !!anomaly_detection_config$source_forecast_column &&
        source_forecast_column_sql == !!anomaly_detection_config$source_forecast_column_sql &&
        source_sql_hash == source_sql_hash
    ) %>% 
    filter(date != '1979-01-01') %>% 
    safe_query(con = con) %>% 
    setDT()
}

create_scd_statement = function(
    select_date_value_sql,
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
        '{current_anomaly_detection_config$source_date_column}' source_date_column,
        '{current_anomaly_detection_config$source_date_column_sql}' source_date_column_sql,
        '{current_anomaly_detection_config$source_forecast_column}' source_forecast_column,
        '{current_anomaly_detection_config$source_forecast_column_sql}' source_forecast_column_sql,
        '{sql(current_anomaly_detection_config$source_sql)}' source_sql,
        '{source_sql_hash}' source_sql_hash,
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
        source_sql_hash,
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
    source_sql_hash,
    {forecast_column_sql}
    date,
    value,
    '{current_timestamp}',
    '{maximum_valid_to}'
  )
")
}