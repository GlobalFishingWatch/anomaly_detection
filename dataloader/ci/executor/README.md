# Anomaly detection data loader

# How-to: Run docker container locally

Minimal command to run docker container locally:
docker run -v ~/.config/gcloud:/root/.config/gcloud anomaly_forecast --environment=dev --config_name=parser_errors_daily

Since the anomaly configurations (config_{environment}.yml) are part of the docker image, it is advisable to make docker build part of the default command to run the container:
docker build . -t anomaly_forecast && docker run -v ~/.config/gcloud:/root/.config/gcloud anomaly_forecast --environment=dev --config_name=parser_errors_daily

# How-to: Regenerate t_{environment}_deltas table
The t_{environment}_deltas table is a table that contains the deltas between the actuals and the forecasted values. It is used to calculate the anomalies. The table is regenerated every time the data loader is run.

After making changes to the query in `sql/t_deltas.sql` you can manually regenerate the table by running the following command:
```bash
# need to replace {PROJECT}, {DATASET} and {ENVIRONMENT} with the respective values
export PROJECT=world-fishing-827
export DATASET=tech_anomaly_detection
export ENVIRONMENT=dev
cat sql/t_deltas.sql | sed "s/{PROJECT}/$PROJECT/g" | sed "s/{DATASET}/$DATASET/g" | sed "s/{ENVIRONMENT}/$ENVIRONMENT/g" | bq query --nouse_legacy_sql
```


# Workflow

The high level workflow when adding a new anomaly configuration is as follows:
1. Everything starts with a hypothesis why a specific measure is worth monitoring, which is often derived from observations in the monitoring dashboard or based on past incidents.
2. Add anomaly configuration in config_{environment}.yaml. For developing and testing anomaly configurations this could happen in the dev and staging environment in order to gain experience how the configuration does in practice and then maybe fine tune.
3. Set anomaly thresholds in /dbt/seeds/thresholds_{environment}.csv and (optionally) provide a description in /dbt/seeds/config_descriptions_{environment}.csv.
4. Run initial full load locally using new anomaly config.
5. Run one incremental load locally.
6. Deploy anomaly config so it runs automatically.
7. Whenever the anomaly threshold is exceeded, the alerting module automatically raises an alert using the defined alerting mechanism, e.g. in a Slack channel.

## Data loader
The data loader ensures that the entire underlying data of historical actual values exists for an anomaly config. It also generates the latest forecasts.

### Configuring anomaly configuration
TODO:

### Set anomaly thresholds and descriptions
Anomaly thresholds and descriptions are static resources that are maintained as csvs in `/dbt/seeds`. Refer to the DBT README in the respective DBT project.

### Initial full load
Every anomaly_config requires that the data history is first processed and loaded into the t_{environment}_actuals table that contains all historical actual values. The table is SCD2 versioned and designed in an efficient way that each row is a key-value pair of timestamp-value-dimension_split_value (along with further metadata).

The initial full load needs to be triggered locally at the moment. Since this is a one-off, the allowed_size arg might have to be provided via the command-line, in case the container fails with a respective column.

### Run incremental load locally
The command for running an incremental load is identical to the command for running a full load, except that the `--timestamp_from` argument doesn't need to be provided but is inferred automatically (either based on the global default value or based on the anomaly config).

### Deploy anomaly config
This project makes use of cloudbuild for CI/CD and all that is required to automatically orchestrate the new anomaly configuration is to commit and push the changes to the repo. For more information on the CI/CD setup refer to the repo's root README.