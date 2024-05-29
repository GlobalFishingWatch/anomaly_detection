# Workflow

1. Generate forecast for latest day.
2. If delta between actual vs forecast exceeds preset threshold an alert is raised.

# Generating Forecasts

## Usage

### Config

Forecasts are configured in config.yml. There are two modes:

1. Specify date and forecast column
2. Manually specify an SQL script

#1 is only possible, if the source table already has the available columns and allows to SUM/COUNT forecast column and GROUP BY `date_column`. If this is not possible, a custom SQL script can be provided that needs to return 2 columns: `timestamp` and `value`.

### Docker

For production purposes a Dockerfile has been provided.

### R

For development and manually generating forecasts you may use the R project which includes `generate_forecasts.R`, which is a wrapper to quickly generate a full load of forecasts.

# Anomaly Configuration

## Data

Each anomaly configuration requires a unique definition for loading the data. The data definition is uniquely specified by:

- dataset
- table
- timestamp column
- value column
- period length

# [Anomaly detection monitoring dashboard](https://lookerstudio.google.com/reporting/1f9b8d37-a87b-4177-a108-3b3e87ce5804)

An dashboard has been created to explore new monitoring opportunities, tweak existing anomaly detection configurations, and debug anomalies after alerts have been triggered.

<img src="README-anomaly-detection-sample.png" width="600" />

# Deploy infrastructure

The infrastructure is deployed using Terraform. The Terraform code related with cloudbuild is located in the `cloudbuild` folder.
The `environments` folder contains the deploy infrastructure for each environment (dev, staging, release(new tag)).

**IMPORTANT**: All changes related with permissions, SA, BigQuery, GCS should be done in the `gfw-terraform-gcp` project. In the environments folder, we only add configuration of Gcloud services like cloud run, scheduler, pubsub, etc

To deploy the cloudbuild, run the following command inside of the cloudbuild folder (This is the unique command of terraform that you need to run and you only need to run it when you change something in the cloudbuild folder):

```bash
# only the first time
terraform init

terraform apply
```

The cloudbuild define 2 triggers:

- one for push to dev and main branch
- one for push to any tag (Release a new version).

Cloudbuild will generate the docker image and deploy the infrastructure for the specified environment, depenging on the branch.

- dev branch: Cloudbuild will deploy the infrastructure for the dev environment (`dev` folder).
- main branch: Cloudbuild will deploy the infrastructure for the main environment (`main` folder).
- new tag: Cloudbuild will deploy the infrastructure for the release environment (`release` folder).
- any other branch: Cloudbuild will skip the `apply` step.

## Deploy folder

The `deploy` folder contains the Terraform code for the infrastructure. The folder contains the following folders:

- `environments`: Contains the Terraform code for each environment (dev, staging, release).
- `template`: Contains the Terraform code for the Services template.

### Environments

Each environment has its own folder. The folder contains the Terraform code for the environment. The folder contains the following files:

- `main.tf`: Contains the Terraform code for the main environment. This file import the template and specify the differet variables for the environment.
- `backend.tf`: Contains the Terraform backend configuration for the environment.

### Template

The `template` folder contains the Terraform code for the template. The folder contains the following files:

- `main.tf`: Contains the GCP services that you want to deploy. It use the `environment` variable to determine which environment to deploy.
- `variables.tf`: Contains the Terraform variables for the template.
