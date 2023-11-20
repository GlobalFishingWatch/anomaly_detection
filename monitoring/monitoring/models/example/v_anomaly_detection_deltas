{{ config(materialized='view') }}

WITH latest_fc AS (
      SELECT 
        * EXCEPT(forecasts, actuals),
        CONCAT(source_dataset, ".", source_table) source_dataset_table,
        CONCAT(source_dataset, ".", source_table, ".", source_forecast_column) source_dataset_table_column,
        CASE WHEN execution_time = MAX(execution_time) OVER (PARTITION BY source_dataset, source_table, source_forecast_column, fc.date) THEN True END AS latest_forecast
      FROM `world-fishing-827.tech_great_expectations.anomaly_detection_forecasts`
      CROSS JOIN UNNEST(forecasts) fc
    ),
    latest_ac AS (
      SELECT 
        * EXCEPT(forecasts, actuals),
        CONCAT(source_dataset, ".", source_table) source_dataset_table,
        CONCAT(source_dataset, ".", source_table, ".", source_forecast_column) source_dataset_table_column,
        CASE WHEN execution_time = MAX(execution_time) OVER (PARTITION BY source_dataset, source_table, source_forecast_column, ac.date) THEN True END AS latest_actual
      FROM `world-fishing-827.tech_great_expectations.anomaly_detection_forecasts`
      CROSS JOIN UNNEST(actuals) ac
    ),
    forecasts_actuals AS (
      SELECT 
        latest_fc.* EXCEPT (date, value), 
        latest_fc.date as forecast_date, 
        latest_fc.value as forecast_value, 
        latest_ac.date actual_date, 
        latest_ac.value actual_value
      FROM latest_fc
      JOIN latest_ac
      USING(source_dataset_table_column, date)
      WHERE latest_forecast 
      AND latest_actual
    )
    SELECT
      DISTINCT
      *,
      actual_value - forecast_value delta,
      (actual_value - forecast_value) / forecast_value delta_rel,
      abs(actual_value - forecast_value) abs_delta,
      abs((actual_value - forecast_value) / forecast_value) abs_delta_rel
    FROM forecasts_actuals