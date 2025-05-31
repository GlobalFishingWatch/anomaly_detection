# Demo Configuration Backup

This directory contains the working demo configurations created during multi-project refactoring.

## Demo Project Details
- **Project**: `anomaly-detection-demo-461518`
- **User**: `christianhomberg@gmail.com`
- **Data Source**: Wikipedia pageviews (public BigQuery dataset)

## Configurations Created
1. **config_descriptions_dev_demo.csv**: Wikipedia-based anomaly detection descriptions
   - `wiki_pageviews_python_daily`: Python-related articles daily pageviews
   - `wiki_pageviews_english_hourly`: All English Wikipedia hourly pageviews
   - `wiki_pageviews_trending_topics_daily`: Trending tech topics daily pageviews

2. **thresholds_dev_demo.csv**: Anomaly detection thresholds for Wikipedia data
   - Tuned for web traffic patterns with higher variance tolerance

3. **config_demo.yaml**: Dataloader configuration using public BigQuery data
   - Uses `bigquery-public-data.wikipedia.pageviews_2024` dataset
   - Custom SQL queries for Python topics, trending topics, and general English pageviews
   - Configured with MSTL, mean, and median forecasting algorithms

## Testing Status
- **DBT seeds**: Successfully deployed to demo project
- **Data access**: Verified Wikipedia data queries work correctly
- **Patterns**: Confirmed realistic weekly/daily patterns in data

## Next Steps
These configurations will be moved to `configs/demo/` in the new multi-project structure.