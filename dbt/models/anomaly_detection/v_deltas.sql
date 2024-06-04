{{ config(
  materialized='view',
  alias='v_' ~ env_var('DBT_ENVIRONMENT') ~'_deltas'
) }}

WITH latest_fc AS (
      SELECT 
        *,
        CONCAT(source_dataset, ".", source_table) source_dataset_table,
        CONCAT(source_dataset, ".", source_table, ".", source_forecast_column) source_dataset_table_column
      FROM `world-fishing-827.tech_anomaly_detection.t_{{ env_var('DBT_ENVIRONMENT') }}_forecasts`
      WHERE valid_to = '9999-12-31 23:59:59 UTC'
    ),
    latest_ac AS (
      SELECT 
        *,
        LAG(value, 365) OVER (
        PARTITION BY 
          config_name,
          dimension_split_value
        ORDER BY timestamp) AS previous_year_actual_value,
        CONCAT(source_dataset, ".", source_table) source_dataset_table,
        CONCAT(source_dataset, ".", source_table, ".", source_forecast_column) source_dataset_table_column
      FROM `world-fishing-827.tech_anomaly_detection.t_{{ env_var('DBT_ENVIRONMENT') }}_actuals`
      WHERE valid_to = '9999-12-31 23:59:59 UTC'
    ),
    forecasts_actuals AS (
      SELECT 
        forecast_method,
        latest_fc.timestamp as forecast_timestamp, 
        latest_fc.value as forecast_value, 
        latest_ac.timestamp actual_timestamp, 
        IFNULL(latest_ac.value, 0) actual_value,
        COALESCE(latest_fc.timestamp, latest_ac.timestamp) timestamp,
        COALESCE(latest_fc.config_name, latest_ac.config_name) config_name,
        COALESCE(latest_fc.dimension_split_value, latest_ac.dimension_split_value) dimension_split_value,
        COALESCE(latest_fc.source_sql, latest_ac.source_sql) source_sql,
        COALESCE(latest_fc.source_sql_hash, latest_ac.source_sql_hash) source_sql_hash,
        COALESCE(latest_fc.source_dataset_table, latest_ac.source_dataset_table) source_dataset_table,
        COALESCE(latest_fc.source_dataset_table_column, latest_ac.source_dataset_table_column) source_dataset_table_column,
        COALESCE(latest_fc.period_length, latest_ac.period_length) period_length,
      FROM latest_ac
      FULL JOIN latest_fc
      USING(config_name, dimension_split_value, timestamp)
    ),
    forecasts_thresholds AS (
      SELECT *
      FROM forecasts_actuals
      LEFT JOIN {{ ref('thresholds_' ~ env_var('DBT_ENVIRONMENT')) }}
      USING(config_name, forecast_method)
    ),
    forecasts_descriptions AS (
      SELECT *
      FROM forecasts_thresholds
      LEFT JOIN {{ ref('config_descriptions_' ~ env_var('DBT_ENVIRONMENT')) }}
      USING(config_name)
    ),
    forecasts_deltas AS (
      SELECT
        DISTINCT
        *,
        actual_value - forecast_value delta,
        SAFE_DIVIDE((actual_value - forecast_value), forecast_value) delta_rel,
        abs(actual_value - forecast_value) abs_delta,
        abs(SAFE_DIVIDE((actual_value - forecast_value), forecast_value)) abs_delta_rel
      FROM forecasts_descriptions
    ),
    forecasts_delta_rel_winsorised AS (
      SELECT
        *,
        CASE WHEN delta_rel > 1 THEN 1
          WHEN delta_rel < -1 THEN -1
          ELSE delta_rel
        END AS delta_rel_winsorised
      FROM forecasts_deltas
    ),
    forecasts_anomaly_type_lower_higher AS (
      SELECT 
        *,
        CASE WHEN 
          delta_rel < critical_lower THEN 'critical_lower'
          WHEN delta_rel < warning_lower THEN 'warning_lower'
          WHEN delta_rel > critical_higher THEN 'critical_higher'
          WHEN delta_rel > warning_higher THEN 'warning_higher'
          ELSE 'normal'
        END AS anomaly_type_lower_higher
      FROM forecasts_delta_rel_winsorised
    ),
    forecasts_anomaly_type AS (
      SELECT 
        *, 
        CASE 
          WHEN anomaly_type_lower_higher LIKE '%critical%' THEN 'critical' 
          WHEN anomaly_type_lower_higher LIKE '%warning%' THEN 'warning' 
          ELSE 'normal' 
      END AS anomaly_type
      FROM forecasts_anomaly_type_lower_higher
    ),
    forecasts_anomaly_value AS (
      SELECT 
        *,
        IF(anomaly_type != 'normal', delta_rel, NULL) anomaly_value,
        IF(anomaly_type != 'normal', delta_rel_winsorised, NULL) anomaly_value_windsorised
      FROM forecasts_anomaly_type
    ),
  forecasts_remove_missing_latest_actuals AS (
    SELECT * FROM forecasts_anomaly_value
    QUALIFY forecast_timestamp IS NULL OR forecast_timestamp <= MAX(actual_timestamp) OVER (PARTITION BY config_name)
  ),
  forecast_anomaly_debounced AS (
    SELECT 
      *,
      CASE 
        WHEN anomaly_type_lower_higher != 'normal' 
          AND LAG(anomaly_type_lower_higher) OVER(PARTITION BY config_name, forecast_method ORDER BY timestamp) = 'normal' 
          THEN anomaly_type_lower_higher
        ELSE NULL
      END anomaly_type_lower_higher_start,
      CASE 
        WHEN anomaly_type_lower_higher = 'normal' 
          AND LAG(anomaly_type_lower_higher) OVER(PARTITION BY config_name, forecast_method ORDER BY timestamp) != 'normal' 
          THEN LAG(anomaly_type_lower_higher) OVER(PARTITION BY config_name, forecast_method ORDER BY timestamp)
        ELSE NULL
      END anomaly_type_lower_higher_end
    FROM forecasts_remove_missing_latest_actuals
  ),
  forecast_anomaly_debounced_values AS (
    SELECT
      *,
      IF(anomaly_type_lower_higher_start != 'normal', anomaly_value_windsorised, NULL) anomaly_value_windsorised_debounced
    FROM forecast_anomaly_debounced
  )

SELECT * FROM forecast_anomaly_debounced_values