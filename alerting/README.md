# Alerting

Slack alerting on top of the anomaly-detection deltas table. Runs as a Cloud Run job on an hourly schedule.

## Architecture

Thread identity is `(config_name, anomaly_date)` where `anomaly_date = DATE(timestamp)` of the offending data point. Every state transition (fire, severity change, resolve) posts a new Slack reply; messages are never edited. A debounced summary reply carries the aggregate count per thread per run. Threads close on all-resolved or a 7-day hard cap.

Per-config aggregation modes (see `state.AGGREGATION_MODE`):

- `thread` (default): opener + per-dim fires + summary replies. Used for configs with a `dimension_split` or multiple anomalies per day.
- `flat-with-resolve-replies`: opener carries the initial fire card; severity changes and resolves still post as replies. Used for hourly configs without a `dimension_split`.
- `flat`: opener IS the alert; no replies. Used for daily single-dim configs.

## Storage

- `t_alerting_incidents` — one row per `(config, anomaly_date)` thread. Tracks `status`, `closed_at`, `slack_ts`, and `summary_counts_json` (debounce key).
- `t_alerting_incident_replies` — append-only event log keyed on `(incident_slack_ts, dimension_split_value, forecast_method)`. "Current state of dim X" = latest non-summary row.

## Entry point

`alerting/ci/executor/main.py`. Orchestrates: query deltas + open incidents → group by `(config, anomaly_date)` → decide actions via the pure `state.process_thread` → apply via `bq.py` + `slack.py`.
