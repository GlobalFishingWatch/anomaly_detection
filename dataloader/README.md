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
    - spire
    - exactearth
    - kpler
  ...
```

Currently deprecated (dev and staging, in both `parsed_row_count_source_daily` and `parser_errors_daily_by_source` unless noted): `marinetraffic` (dead since 2026-01-01; `parsed_row_count_source_daily` only — excluded from `parser_errors_daily_by_source` via `source_filter_sql`), `ais-listener` (2026-05-04), `kpler` (2026-05-08 — superseded by the live `kpler-satellite` / `kpler-terrestrial` / `kpler-roaming` split dims), `spire` and `exactearth` (ingestion stopped 2026-06-03).

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

## Refetching recent days (time-evolving metrics)

The default delta-load logic only fetches *missing* timestamps — once a `(config, date)` row exists for any dim, that date is skipped on subsequent runs. That's correct for configs whose value is stable once the day ends (row counts, error counts) but **breaks** for configs whose source metric evolves with wall-clock time.

Concrete example: `gfw_api_delays`'s `timestamp_delay_now_hypothetical_vs_expected_delay_hour` is computed against `CURRENT_TIMESTAMP()` inside `v_scraped_api_values`. A `(dim, date)` row's value grows every hour the data remains unpublished. If sibling dims arrive on time, the date is recorded in actuals at low value; later, when this dim's metric crosses the alert threshold, the date is no longer "missing" so the source query never refetches it — the alert silently never fires.

To opt a config into refetching, add `refetch_recent_days: <N>` to its YAML block:

```yaml
gfw_api_delays:
  ...
  refetch_recent_days: 14
```

`forecast.R` then forces the last N days back into the refetch set every run: the source query returns them, and the SCD2 MERGE in `create_scd_statement` upserts — unchanged values are no-ops, value changes get a new `is_latest=TRUE` row (the old value is versioned out). The alerter sees the latest value on the next deltas refresh.

Pick N to cover the expected window of the metric. For `gfw_api_delays` the relevant `expected_delay_hour` values in `t_expected_publication_lags` top out at ~80 hours (~3.3 days); `N=14` covers that plus ~10 days of post-expected drift before we accept the value as final.

The sibling-dim masking above isn't the only failure mode. `s2_index_delays` has no `dimension_split`, yet needs refetching too: its `source_filter_sql` only returns rows while `timestamp_lag_minute_now_hypothetical > 0`, so a date enters actuals the first run after it turns late and freezes at that first-observed value. Because the cron fetches at 10:20 UTC, first-observed values quantize to ~627 minutes (turned late before the same-day fetch) or ~2062 minutes (turned late after it, picked up next day) — a date could never exceed ~2062 no matter how stale the index actually got, which made any threshold above that unreachable. With `refetch_recent_days: 14` the recorded delay keeps growing daily until the data publishes, so the `s2_index_delays` thresholds (warning > ~35h, critical > ~48h, set 2026-06-12 from the 2026 baseline) work as intended.

Currently set: `gfw_api_delays` (N=14), `s2_index_delays` (N=14).

Configs without this field behave exactly as before (no extra source-query cost).

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

## Cold-start backfill when deploying a config to a new environment

The scheduled (automated) runs query only *missing* timestamps and are capped at the
default `allowed_size` of **60 GB** (`--allowed_size` in `forecast.R`, enforced by
`validate_query_size` in `bq_utils.R`). That cap is deliberately tight so a routine daily
run can never silently bill a large scan.

The **first** run of a config in an environment is different: the actuals table is empty, so
the source query scans the config's entire history in one shot. For configs that read a large
source table this easily exceeds 60 GB and the run fails with `Query exceeds allowed_size`.
This is expected, not a bug — the daily incremental runs that follow are cheap and stay well
under the cap.

**Policy:** when you deploy a config to a new environment (dev → staging → prod), the person
doing the promotion is responsible for running the initial backfill **manually**, before the
scheduler's first automated run does. Because it is a manual, supervised, one-off run, the
operator **is allowed to raise `--allowed_size`** for it (this is the one sanctioned exception
to "don't raise cost thresholds without checking" — it applies only to the manual cold-start
backfill, never to the committed config or the scheduled job).

Size the override from a dry run rather than guessing. The query is partition- and
cluster-pruned at runtime, so `validate_query_size`'s estimate (a dry-run upper bound that
cannot see clustering) is usually much larger than the bytes actually billed — set
`--allowed_size` just above that estimate:

```bash
# 1. estimate: dry-run the config's full-history source scan and read the upper bound
bq query --project_id=world-fishing-827 --use_legacy_sql=false --dry_run '<full-history source query>'

# 2. backfill: replicate the scheduler's args, add --allowed_size above the estimate.
#    Use a custom (^@^) delimiter so the space in "7 days" stays inside one arg.
gcloud run jobs execute qa-gfw-anomaly-detection-dataloader-staging \
  --project=world-fishing-827 --region=us-central1 --wait \
  --args="^@^--environment=staging@--anomaly_detection_config_name=<config>@--forecast_timestamp_from=7 days@--allowed_size=<GB above estimate>"
```

Do **not** bake the raised value into `config_<env>.yaml` (the per-config `allowed_size` field)
or into the scheduled job — that would lift the guardrail for every future run. The override
lives only on the manual execution.
