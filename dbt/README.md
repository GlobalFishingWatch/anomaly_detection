# Anomaly detection - DBT

## Description
We use dbt to maintain several hard coded configurations in dbt seeds:
 - thresholds_{environment}: these tables contain anomaly alert thresholds, based upon which alerts with different criticality levels are triggered and visualised in Looker dashboards
 - config_descriptions_{environmnet}: these tables contain anomaly configuration descriptions which can be included in anomaly alerts as well as Looker dashboards to provide details about anomalies

 We also include views that calculate whether anomaly thresholds are exceeded and aggregate data for alerting and the Looker dashboard:
  - v_deltas: this view combines forecasts with actuals, as well as thresholds and descriptions. It also applies debouncing, so anomaly alerts are only send out the first time an anomaly starts and not on subsequent periods

## Workflow
We maintain the lookup files for each environment independently. Run the following command to set the corresponding environment in DBT based on the current git branch:
`source setenv.sh`

Currently, there's no automation of DBT, so you need to run `dbt seed` from the command line.