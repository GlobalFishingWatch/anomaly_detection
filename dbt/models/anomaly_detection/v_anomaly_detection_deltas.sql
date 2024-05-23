{{ config(
  materialized='view',
  alias='v_' ~ env_var('DBT_ENVIRONMENT') ~'_anomaly_detection_deltas'
) }}

WITH latest_fc AS (
      SELECT 
        *,
        CONCAT(source_dataset, ".", source_table) source_dataset_table,
        CONCAT(source_dataset, ".", source_table, ".", source_forecast_column) source_dataset_table_column,
        CONCAT(source_dataset, ".", source_table, ".", source_forecast_column, ".", source_timestamp_column_sql, ".", 
        source_forecast_column_sql, ".", source_sql_hash, ".", period_length) forecast_actuals_join_key,
        IFNULL(low_confidence, 0.2) low_confidence_upper,
        IFNULL(-low_confidence, -0.2) low_confidence_lower,
        IFNULL(high_confidence, 0.5) high_confidence_upper,
        IFNULL(-high_confidence, -0.5) high_confidence_lower
      FROM `world-fishing-827.tech_great_expectations.{{ env_var('DBT_ENVIRONMENT') }}_anomaly_detection_forecasts`
      WHERE valid_to = '9999-12-31 23:59:59 UTC'
    ),
    latest_ac AS (
      SELECT 
        *,
        LAG(value, 365) OVER (
        PARTITION BY 
          source_dataset,
          source_table,
          source_timestamp_column,
          source_timestamp_column_sql,
          source_forecast_column,
          source_forecast_column_sql,
          source_sql,
          source_sql_hash
        ORDER BY timestamp) AS previous_year_actual_value,
        CONCAT(source_dataset, ".", source_table) source_dataset_table,
        CONCAT(source_dataset, ".", source_table, ".", source_forecast_column) source_dataset_table_column,
        CONCAT(source_dataset, ".", source_table, ".", source_forecast_column, ".", source_timestamp_column_sql, ".", 
        source_forecast_column_sql, ".", source_sql_hash, ".", period_length) forecast_actuals_join_key
      FROM `world-fishing-827.tech_great_expectations.{{ env_var('DBT_ENVIRONMENT') }}_anomaly_detection_actuals`
      WHERE valid_to = '9999-12-31 23:59:59 UTC'
    ),
    forecasts_actuals AS (
      SELECT 
        forecast_method,
        low_confidence_upper,
        low_confidence_lower,
        high_confidence_upper,
        high_confidence_lower,
        latest_fc.timestamp as forecast_timestamp, 
        latest_fc.value as forecast_value, 
        latest_ac.timestamp actual_timestamp, 
        IFNULL(latest_ac.value, 0) actual_value,
        COALESCE(latest_fc.timestamp, latest_ac.timestamp) timestamp,
        COALESCE(latest_fc.config_name, latest_ac.config_name) config_name,
        COALESCE(latest_fc.source_sql, latest_ac.source_sql) source_sql,
        COALESCE(latest_fc.source_sql_hash, latest_ac.source_sql_hash) source_sql_hash,
        COALESCE(latest_fc.source_dataset_table, latest_ac.source_dataset_table) source_dataset_table,
        COALESCE(latest_fc.source_dataset_table_column, latest_ac.source_dataset_table_column) source_dataset_table_column,
        COALESCE(latest_fc.period_length, latest_ac.period_length) period_length,
      FROM latest_ac
      FULL JOIN latest_fc
      USING(forecast_actuals_join_key, timestamp)
    )
    SELECT
      DISTINCT
      *,
      actual_value - forecast_value delta,
      SAFE_DIVIDE((actual_value - forecast_value), forecast_value) delta_rel,
      abs(actual_value - forecast_value) abs_delta,
      abs(SAFE_DIVIDE((actual_value - forecast_value), forecast_value)) abs_delta_rel,
      low_confidence_lower + abs(SAFE_DIVIDE((actual_value - forecast_value), forecast_value)) distance_from_lower_threshold,
      high_confidence_lower + abs(SAFE_DIVIDE((actual_value - forecast_value), forecast_value)) distance_from_higher_threshold
    FROM forecasts_actuals
  