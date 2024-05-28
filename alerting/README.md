# Alerting

Building on the data load and forecasting module for anomaly detection, we set up alerting on the BQ view which contains a summary of all anomalies as well as some information like criticality, dataset, table, column, and deviation from the forecast.

## Architecture

The alerting function runs in a cloud run job. In it's current setup, it queries the anomaly summary table for all anomalies on the day that it is invoked and sends out a Slack notification for each anomaly, including some context information.