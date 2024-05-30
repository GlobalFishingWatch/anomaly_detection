# Data Load

The data loader is the basis for anomaly detection alerting and monitoring. It loads time series data and applies various forecasting algorithms based on configurations to calculate expected values for a time period. The data actuals and forecasts are loaded into BQ tables and views that provide the data in the right format for alerting and monitoring.

## Architecture

The data loader runs in a cloud run job.