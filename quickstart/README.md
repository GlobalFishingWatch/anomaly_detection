# 🚀 Quickstart Demo

This directory contains a minimal working example of the anomaly detection system using public BigQuery data.

## What's Included

- **config_demo.yaml**: Anomaly detection configuration for NYC Citibike data
- **docker-compose.yml**: Docker setup to run the demo locally
- **run_demo.sh**: Script to execute the complete demo workflow

## Public Data Used

**Dataset**: NYC Citibike trip data from `bigquery-public-data.new_york_citibike.citibike_trips`

**Metrics Monitored**:
- Daily trip counts (expects weekly/seasonal patterns)
- Average trip duration (detects weather/event impacts)

## Expected Results

The demo will:
1. ✅ Generate forecasts using MSTL and mean algorithms
2. ✅ Store results in your BigQuery dataset
3. ✅ Show forecast accuracy and any detected anomalies
4. 📊 Create tables you can query and visualize

## Quick Start

```bash
# Set up environment variables
export GCP_PROJECT_ID="your-project-id"
export BQ_DATASET="anomaly_detection_demo"

# Run the demo
docker-compose up --build

# View results
docker-compose --profile results up results-viewer
```

## Customization

- **Different Data**: Edit `config_demo.yaml` to point to your own BigQuery tables
- **More Algorithms**: Add additional forecasting methods in the config
- **Time Ranges**: Adjust the date filters in the SQL queries
- **Thresholds**: Add anomaly detection thresholds (requires DBT setup)

## Next Steps

1. 🔍 **Explore Results**: Query the generated tables in BigQuery
2. 🎯 **Add Alerting**: Set up the alerting component with Slack
3. 🏗️ **Deploy**: Use Terraform to deploy to Cloud Run
4. 📊 **Monitor**: Connect to Looker Studio for dashboards