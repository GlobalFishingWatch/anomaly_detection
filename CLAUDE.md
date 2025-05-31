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

### Demo Project Setup
**IMPORTANT: For demo project `anomaly-detection-demo-461518`, use user: `christianhomberg@gmail.com`**

#### Project-Specific gcloud Configuration
To isolate the demo project and avoid authentication conflicts with other projects:

```bash
# Create dedicated configuration for anomaly detection demo
gcloud config configurations create anomaly-demo
gcloud config configurations activate anomaly-demo
gcloud config set account christianhomberg@gmail.com
gcloud config set project anomaly-detection-demo-461518

# Set up Application Default Credentials for Terraform
gcloud auth application-default login
```

#### Switching Between Projects
```bash
# Switch to demo project
gcloud config configurations activate anomaly-demo

# Switch back to other projects
gcloud config configurations activate default  # or other config name

# List all configurations
gcloud config configurations list
```

This approach ensures:
- Demo project uses correct user account
- No interference with other GCP projects/accounts
- Clean separation for development work
- Terraform authentication works correctly

### Multi-Project Support
**This repository supports multiple organizations/projects simultaneously**

#### Project Configuration Structure
```
configs/
├── world-fishing-827/              # GFW production configurations
├── anomaly-detection-demo-461518/  # Demo project configurations  
├── template/                       # Template for new projects
└── your-project-id/                # Your custom project
```

#### Usage

**Project Switching:**
```bash
# Use the project switcher script (recommended)
source scripts/set-project.sh anomaly-detection-demo-461518   # Demo project
source scripts/set-project.sh world-fishing-827              # GFW production
source scripts/set-project.sh your-project-id                # Your project
```

**Operations with Active Project:**
```bash
# DBT operations use project-specific configurations
cd dbt && source setenv.sh  # Sets up project-specific seed paths
dbt seed                     # Uses configs/$ANOMALY_PROJECT/dbt_seeds/

# Docker operations use project-specific configs
./scripts/docker-run.sh dataloader  # Uses configs/$ANOMALY_PROJECT/dataloader/

# Quick start for new users
./scripts/quick-start.sh  # Interactive project selection and setup
```

- See `configs/README.md` for complete multi-project usage guide
- See `configs/template/README.md` for new project setup instructions

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

## Refactoring Progress Checkpoint

### Current Status (Branch: refactor/multi-project-support)
**Major refactoring completed for multi-project GCP support** - System can now be deployed to any GCP project instead of being hardcoded to `world-fishing-827`.

### Key Changes Implemented:
1. **Infrastructure Parameterization**:
   - Added `terraform.tfvars.example` template for project-specific configuration
   - All Terraform modules now accept: project ID, service account email, docker registry as variables
   - Removed hardcoded references to `world-fishing-827` throughout codebase

2. **Environment Variable Support**:
   - Alerting Python code now uses `GCP_PROJECT_ID` and `BQ_DATASET` environment variables
   - Runtime configuration flexible across different projects

3. **Documentation Enhancement**:
   - `PROJECT_SETUP.md`: Complete step-by-step guide for new GCP project setup
   - `project-config.yaml`: Configuration template with examples for dev/test/prod
   - Updated CLAUDE.md with multi-project guidance

4. **Alerting System Improvements**:
   - Migrated from Slack webhooks to Slack WebClient API for better reliability
   - Environment-specific Slack channel routing via seed files
   - Enhanced deduplication logic with configurable time windows

5. **Environment Standardization**:
   - Renamed "release" environment to "prod" for consistency
   - Added complete seed file sets for staging/prod environments
   - Environment-specific threshold and configuration management

### Files Ready for Commit:
- `DEV_SETUP.md` (untracked)
- `QUICKSTART.md` (untracked) 
- `quickstart/` directory (untracked)

### End User Testing Progress:
**COMPLETED:**
1. **Environment Setup**: 
   - GCP Project: `anomaly-detection-demo-461518` (verified active)
   - Environment variables: `GCP_PROJECT_ID` and `BQ_DATASET` configured
   - `terraform.tfvars` created and customized for demo project
   - BigQuery dataset `tech_anomaly_detection` created successfully

2. **DBT Environment**:
   - `setenv.sh` works correctly (sets `DBT_ENVIRONMENT=dev` on refactor branch)
   - Environment detection logic working as expected

**ISSUE DISCOVERED:**
3. **Configuration Dependencies**: Current seed files and dataloader configs are GFW-specific
   - `dbt/seeds/*_dev.csv` reference non-existent datasets/tables in demo project
   - `dataloader/ci/executor/config_dev.yaml` hardcodes `world-fishing-827` project references
   - Need demo-specific configurations for proper end user testing

**COMPLETED:**
4. **Demo Configurations Created**: 
   - Wikipedia pageviews-based configurations using public BigQuery data
   - Three realistic demo configs: Python topics daily, English hourly, trending topics daily
   - Tested data access - works perfectly with clear weekly patterns
   - Self-contained configurations requiring no private data

**COMPLETED:**
5. **DBT Operations Successful**: 
   - Virtual environment activation required (venv/bin/activate)
   - DBT seed operations work correctly with demo configurations
   - Environment setup (setenv.sh) functions as expected 
   - Demo seed tables created successfully in BigQuery

**COMPLETED:**
6. **Docker Development Workflow**: 
   - Docker build successful, container starts and loads configuration correctly
   - GCP authentication working via volume mount, R environment functional

**CRITICAL ISSUES DISCOVERED:**
7. **Environment Parameter Missing**: 
   - R script expects `--environment dev` command line argument, not just env vars
   - Current run: `t__actuals` (missing environment) should be `t_dev_actuals`
   - Need to pass environment parameter to Docker container

8. **Remote State Not Generalized**: 
   - `backend.tf` files hardcode `skytruth-pelagos-production-tfstate-us-central1` bucket
   - Demo projects can't access this bucket - need project-specific remote state
   - All backend.tf files need parameterization for multi-project support

9. **Infrastructure Dependencies**: 
   - Missing tables: `t_dev_actuals`, `t_dev_forecasts` 
   - Created by Terraform in `/deploy` directories
   - Need to deploy infrastructure before dataloader can run

**GENERALIZATION REQUIREMENTS:**
- Remote state buckets must be project-specific
- Backend configuration needs to be templated
- Environment parameter handling needs documentation

**COMPLETED:**
10. **Bootstrap Terraform Setup**: Created `/terraform/bootstrap/` for managing remote state bucket with local state

**AUTHENTICATION APPROACH DOCUMENTED:**
11. **gcloud Configuration Management**: Documented project-specific authentication approach
    - Created instructions for `anomaly-demo` gcloud configuration
    - Isolates demo project from other GCP projects/accounts
    - Proper Application Default Credentials setup for Terraform
    - Added to bootstrap/README.md and CLAUDE.md

**COMPLETED:**
12. **Authentication Success**: Project-specific gcloud configuration working
    - `anomaly-demo` configuration active with `christianhomberg@gmail.com`
    - Application Default Credentials authenticated correctly
    - Browser authentication with checkboxes completed successfully

13. **Remote State Bucket Created**: Bootstrap Terraform successful
    - Bucket: `anomaly-detection-demo-461518-tfstate` created with versioning
    - Lifecycle rules configured for automatic cleanup
    - Ready for use by other Terraform modules

**PENDING:**
14. Update backend.tf files to use project-specific bucket
15. Fix environment parameter passing to Docker
16. Deploy infrastructure to create required tables
17. Test complete dataloader workflow

### Architecture Benefits Achieved:
- **Isolation**: Teams can run independent instances without conflicts
- **Flexibility**: Easy deployment to any GCP project with proper permissions
- **Maintainability**: Centralized configuration through environment variables and Terraform
- **Documentation**: Clear setup guides for new users and projects

## Important Instructions
- **NO EMOJIS**: Never use emojis anywhere - not in code, comments, documentation, commit messages, or output text
- Follow existing code style and conventions
- Prefer editing existing files over creating new ones