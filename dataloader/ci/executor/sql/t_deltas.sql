CREATE OR REPLACE TABLE `{PROJECT}.{DATASET}.t_{ENVIRONMENT}_deltas`
PARTITION BY TIMESTAMP_TRUNC(actual_timestamp, MONTH)
CLUSTER BY config_name, forecast_method, actual_timestamp
AS
WITH latest_fc AS (
      SELECT 
        *,
        CONCAT(source_dataset, ".", source_table) source_dataset_table,
        CONCAT(source_dataset, ".", source_table, ".", source_forecast_column) source_dataset_table_column
      FROM `{PROJECT}.{DATASET}.t_{ENVIRONMENT}_forecasts`
      WHERE valid_to = '9999-12-31 23:59:59 UTC'
    ),
    latest_ac AS (
      SELECT 
        *,
        CONCAT(source_dataset, ".", source_table) source_dataset_table,
        CONCAT(source_dataset, ".", source_table, ".", source_forecast_column) source_dataset_table_column
      FROM `{PROJECT}.{DATASET}.t_{ENVIRONMENT}_actuals`
      WHERE valid_to = '9999-12-31 23:59:59 UTC'
    ),
    forecasts_actuals AS (
      SELECT 
        forecast_method,
        latest_fc.timestamp as forecast_timestamp, 
        ROUND(latest_fc.value, 6) as forecast_value, 
        latest_ac.timestamp actual_timestamp, 
        latest_ac.valid_from delta_valid_from,
        ROUND(IFNULL(latest_ac.value, 0), 6) actual_value,
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
      LEFT JOIN `{PROJECT}.{DATASET}.t_thresholds_{ENVIRONMENT}`
      USING(config_name, forecast_method)
    ),
    forecasts_trehsolds_boundaries AS (
      SELECT 
        *, 
        forecast_value * (1 + critical_lower) critical_lower_value, 
        forecast_value * (1 + warning_lower) warning_lower_value, 
        forecast_value * (1 + warning_higher) warning_higher_value, 
        forecast_value * (1 + critical_higher) critical_higher_value,
        forecast_value * critical_lower critical_lower_delta_threshold, 
        forecast_value * warning_lower warning_lower_delta_threshold, 
        forecast_value * warning_higher warning_higher_delta_threshold, 
        forecast_value * critical_higher critical_higher_delta_threshold
      FROM forecasts_thresholds
    ),
    forecasts_descriptions AS (
      SELECT *
      FROM forecasts_trehsolds_boundaries
      LEFT JOIN `{PROJECT}.{DATASET}.t_config_descriptions_{ENVIRONMENT}`
      USING(config_name)
    ),
    forecasts_deltas AS (
      SELECT
        DISTINCT
        *,
        ROUND(actual_value - forecast_value, 6) delta,
        ROUND(SAFE_DIVIDE((actual_value - forecast_value), forecast_value), 6) delta_rel,
        ROUND(abs(actual_value - forecast_value), 6) abs_delta,
        ROUND(abs(SAFE_DIVIDE((actual_value - forecast_value), forecast_value)), 6) abs_delta_rel
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
        END AS anomaly_type_lower_higher,
        CASE WHEN 
          delta_rel < critical_lower THEN critical_lower
          WHEN delta_rel < warning_lower THEN warning_lower
          WHEN delta_rel > critical_higher THEN critical_higher
          WHEN delta_rel > warning_higher THEN warning_higher
          ELSE 0
        END AS exceeded_threshold_lower_higher
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
          AND LAG(anomaly_type_lower_higher) OVER(PARTITION BY config_name, forecast_method, dimension_split_value ORDER BY timestamp) = 'normal' 
          THEN anomaly_type_lower_higher
        ELSE NULL
      END anomaly_type_lower_higher_start,
      CASE 
        WHEN anomaly_type_lower_higher = 'normal' 
          AND LAG(anomaly_type_lower_higher) OVER(PARTITION BY config_name, forecast_method, dimension_split_value ORDER BY timestamp) != 'normal' 
          THEN LAG(anomaly_type_lower_higher) OVER(PARTITION BY config_name, forecast_method, dimension_split_value ORDER BY timestamp)
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