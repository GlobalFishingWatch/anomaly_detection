# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Architecture Overview

This is a three-component anomaly detection system for maritime data monitoring at Global Fishing Watch:

- **Dataloader (R)**: Generates time series forecasts using MSTL, mean, and median algorithms from BigQuery data
- **Alerting (Python)**: Monitors anomalies and sends Slack notifications when thresholds are exceeded  
- **DBT**: Manages lookup tables, thresholds, and creates the core `v_deltas` view combining forecasts with actuals

## Key Commands

### DBT Operations
```bash
# Set environment based on git branch (dev for non-main, staging for main)
cd dbt && source setenv.sh

# Deploy seed files for current environment
dbt seed
```

### Docker Development
```bash
# Run dataloader locally
cd dataloader/ci/executor && docker-compose up

# Run alerting locally  
cd alerting/ci/executor && docker-compose up
```

### Infrastructure Deployment
```bash
# Deploy Cloud Build triggers (one-time setup)
cd cloudbuild && terraform init && terraform apply

# Infrastructure auto-deploys based on git branch:
# - dev branch → dev environment
# - main branch → main environment  
# - tags → release environment
```

## Project Configuration

### Multi-Project Support
- System now supports multiple GCP projects for development/testing
- Project configuration managed via environment variables and Terraform variables
- See `PROJECT_SETUP.md` for complete setup guide for new projects

### Environment Variables
```bash
# Required for runtime
export GCP_PROJECT_ID="your-project-id"
export BQ_DATASET="tech_anomaly_detection"
export DBT_ENVIRONMENT="dev"  # Set by setenv.sh
```

### Terraform Configuration
- Copy `terraform.tfvars.example` to `terraform.tfvars`
- Update with your project-specific values:
  - `project`: GCP project ID
  - `service_account_email`: Service account for Cloud Run
  - `docker_registry`: Container registry URL

## Configuration Patterns

### Anomaly Configurations
- Located in `dataloader/ci/executor/config.yaml`
- Each config defines: source dataset/table, timestamp/value columns, forecasting algorithms with parameters
- Use custom SQL queries for complex data extraction that can't use simple SUM/COUNT GROUP BY patterns

### Environment-Specific Settings
- Three environments: dev, staging, prod
- Environment-specific files in `dbt/seeds/`: thresholds, config descriptions, Slack channel mappings
- DBT environment set automatically by `setenv.sh` based on git branch

### Thresholds and Alerting
- Critical/warning thresholds defined in `dbt/seeds/thresholds_{environment}.csv`
- Slack channel routing configured in `slack_channels_environments_config_mapping.csv`
- Hash-based deduplication prevents duplicate alerts

## Data Flow

1. **Dataloader**: R scripts query BigQuery, apply forecasting algorithms, store results in `t_{env}_forecasts` and `t_{env}_actuals` tables
2. **DBT**: Combines forecasts/actuals in `v_deltas` view, applies thresholds and debouncing logic
3. **Alerting**: Python queries anomaly summary, sends Slack notifications for threshold breaches
4. **Monitoring**: Looker Studio dashboard provides visualization and debugging

## Development Considerations

- **Cost Control**: Avoid running dataloader directly on large tables (hundreds of GB+) - use monitoring module from monitoring repo for stable intermediate tables
- **Environment Management**: Use `setenv.sh` before DBT operations to ensure correct environment targeting
- **Algorithm Selection**: Choose appropriate forecasting algorithms based on data seasonality (MSTL for seasonal data, mean/median for simpler patterns)
- **Project Setup**: For new development projects, follow `PROJECT_SETUP.md` guide
- **Service Accounts**: Production uses `qa-anomaly-detection@world-fishing-827.iam.gserviceaccount.com`; dev projects should create their own

## New Project Setup

To set up anomaly detection in a new GCP project:

1. **Follow Setup Guide**: See `PROJECT_SETUP.md` for complete instructions
2. **Environment Variables**: Set `GCP_PROJECT_ID` and `BQ_DATASET` for your project
3. **Terraform Variables**: Update `terraform.tfvars` with project-specific values
4. **DBT Configuration**: Use `source setenv.sh` to set correct environment
5. **Service Account**: Create dedicated service account with required BigQuery/Cloud Run permissions

## Monitoring and Debugging

- **Dashboard**: [Looker Studio dashboard](https://lookerstudio.google.com/reporting/1f9b8d37-a87b-4177-a108-3b3e87ce5804) for exploring monitoring opportunities and debugging anomalies
- **Tables**: Check `t_{env}_deltas` for anomaly detection results, `t_{env}_forecasts` for prediction outputs
- **Logs**: Cloud Run job logs in GCP Console for runtime debugging