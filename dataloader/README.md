# Data Load

The data loader is the basis for anomaly detection alerting and monitoring. It loads time series data and applies various forecasting algorithms based on configurations to calculate expected values for a time period. The data actuals and forecasts are loaded into BQ tables and views that provide the data in the right format for alerting and monitoring.

## Architecture

The data loader runs in a cloud run job.

## Deprecating dims and configs

Two distinct kinds of deprecation happen often enough to be worth documenting:

1. **A specific dimension within a config is no longer worth tracking.** The dim has stopped publishing (the source went dead), has been retired by the upstream team, or has shifted to a new level that the historical baseline can never adapt to. The rest of the config is still meaningful — sibling dims keep producing useful signal.
2. **An entire config is no longer worth running.** The metric is decommissioned, the source table is going away, or the team has decided the noise outweighs the value.

These two cases use different mechanisms.

### Deprecating a dim

Add the dim's `dimension_split_value` to `deprecated_dims` in the relevant config block of `config_<env>.yaml`:

```yaml
parsed_row_count_source_daily:
  ...
  dimension_split: value
  deprecated_dims:
    - marinetraffic
    - ais-listener
  ...
```

`forecast.R` reads this list right after building `dt_train` and drops matching rows before the forecast loop runs. Net effect: no new forecasts are generated for the listed dims, so deltas stops gaining new rows, so the alerter stops firing on them.

Important properties:

- **`deprecated_dims` is the only thing you have to set.** No matching change anywhere else.
- **Actuals are unaffected.** Historical actuals stay in `t_dev_actuals` for forensic / dashboard purposes. If the source ever resumes publishing, the new actuals get recorded normally — they just don't feed forecast training as long as the dim is in `deprecated_dims`.
- **Un-deprecation is a clean YAML edit.** Remove the line, push, the next dataloader cron picks the dim back up and forecasts resume.
- **No time-bounded silencing.** This is for permanent (or indefinite) deprecation. If you genuinely need "silence for 2 weeks" semantics, that's a separate concern — talk to the alerting team.

Behaviour timeline after adding a dim:

| Time | What happens |
|---|---|
| T+0 | YAML edit pushed; Cloud Build rebuilds dataloader image. |
| T+~10 min | New image deployed to Cloud Run. |
| T+next cron (10:20 UTC) | First run with the filter active. Forecast loop skips the dim; a log line confirms how many actuals rows were dropped. Forecasts table stops accumulating new rows for the dim. |
| T+~7 days | Forecasts generated *before* deprecation roll out of the alerter's window. New threads stop opening for the dim. Existing open incidents hit the 7-day hard cap and get silenced. |
| T+~30 days | Last historical references age out of the alerter's 30-day window. Looker dashboards filtering by recent date stop showing the dim. |

`source_filter_sql` is a related but different mechanism: it filters the *source query*, so no new actuals are inserted at all. Use it when you want to permanently stop collecting data for a dim or when the source query would otherwise return rows you actively don't want recorded. For pure forecast/alert deprecation, `deprecated_dims` is enough.

### Deprecating a whole config

Three or four steps:

1. **Remove the config block** from `config_<env>.yaml` for every environment you want to deprecate in.
2. **Remove the matching `google_cloud_scheduler_job`** from `dataloader/deploy/template/main.tf`. The scheduler will otherwise keep invoking the dataloader for a config that no longer exists.
3. *(Optional)* Tombstone historical actuals / forecasts / deltas by setting `is_latest=FALSE` if you want the data immediately invisible to Looker. Otherwise the rows stay and roll off rolling-window dashboards over time.
4. *(Optional)* Close any still-open incidents: `UPDATE t_qa_..._alerting_<env>_incidents SET status='resolved', closed_at=CURRENT_TIMESTAMP() WHERE config_name='<deprecated>' AND status='open'`. Without this, open incidents age out via the 7-day hard cap and get caught by the alerter's silencing filter.

Both optional steps are about how quickly you want the deprecated config to disappear from view; functional correctness doesn't require either.

## Workflow

### CI/CD (default)

Cloud Build picks up changes under `dataloader/**` and runs `terraform apply` for the env that matches the branch. Pushing to `dev` rebuilds the image and applies dev terraform; tag releases promote to staging/prod.

### Manual override

For ad-hoc runs (debugging, backfills, deprecation verification):

```bash
gcloud run jobs execute qa-gfw-anomaly-detection-dataloader-dev \
  --project world-fishing-827 \
  --region us-central1 \
  --args=--environment=dev,--anomaly_detection_config_name=<config>,--forecast_timestamp_from='7 days'
```
