# Alerting

Slack alerting on top of the anomaly-detection deltas table. Runs as a Cloud Run job on an hourly schedule.

## Architecture

Thread identity is `(config_name, anomaly_date)` where `anomaly_date = DATE(timestamp)` of the offending data point. Every state transition (fire, severity change, resolve) posts a new Slack reply; messages are never edited. A debounced summary reply carries the aggregate count per thread per run. Threads close on all-resolved or a 7-day hard cap.

Per-config aggregation modes (see `state.AGGREGATION_MODE`):

- `thread` (default): opener + per-dim fires + summary replies. Used for configs with a `dimension_split` or multiple anomalies per day.
- `flat-with-resolve-replies`: opener carries the initial fire card; severity changes and resolves still post as replies. Used for hourly configs without a `dimension_split`.
- `flat`: opener IS the alert; no fire/severity/summary replies — only the final close message still posts as a thread reply. Used for daily single-dim configs.

## Storage

- `t_alerting_incidents` — one row per `(config, anomaly_date)` thread. Tracks `status`, `closed_at`, `slack_ts`, and `summary_counts_json` (debounce key).
- `t_alerting_incident_replies` — append-only event log keyed on `(incident_slack_ts, dimension_split_value, forecast_method)`. "Current state of dim X" = latest non-summary row.

## Entry point

`alerting/ci/executor/main.py`. Orchestrates: query deltas + open incidents → group by `(config, anomaly_date)` → decide actions via the pure `state.process_thread` → apply via `bq.py` + `slack.py`.

## Channel routing

Each thread's channel comes from the `slack_channels_environments_config_mapping` dbt seed — a single table shared by all environments, and **not** re-seeded by CI: after editing the CSV, run `dbt seed --select slack_channels_environments_config_mapping` manually.

`bq.get_channel_config` resolves in two tiers: an exact `(config_name, environment)` row wins, else the environment's fallback row (`config_name` empty). When neither exists the lookup raises; `main.run` catches it, logs a `[channel-routing] skipping ...` error, and continues with the remaining threads — an unmapped config never blocks the rest of the run and is never routed to a guessed channel, but its alerts are dropped until a mapping row lands. dev and staging have fallback rows; prod intentionally has none, so **every prod config needs an explicit mapping row before promotion**.

## First-seen-config bootstrap

When a config is seen by the alerter for the first time (no rows in `t_alerting_incidents` for that `config_name`), every `(config, anomaly_date)` pair with `anomaly_date < today` is silently *bootstrapped*: a `status='resolved'` row is inserted with a synthetic `slack_ts` starting with `BOOTSTRAP-`, and no Slack message is posted. Today's anomalies still flow through the normal alerting path so a brand-new config can still alert on day one.

This prevents the wave of historical notifications that would otherwise hit Slack when a previously-broken or newly-enabled config's dataloader backfills 30 days of anomalies at once.

Bootstrap rows act as permanent "do not alert" markers: every subsequent run queries `STARTS_WITH(slack_ts, 'BOOTSTRAP-')` via `bq.list_bootstrapped_pairs` and drops matching deltas before grouping, so the state machine never sees them again.

## Per-config metadata (DQ dashboard, mentions)

Two optional columns on the `config_descriptions_<env>` dbt seed control extra rendering. Both ride the existing `LEFT JOIN ... USING(config_name)` in `dataloader/ci/executor/sql/t_deltas.sql`, so once the column is filled in the seed CSV and dbt + the dataloader rebuild downstream tables, the alerter picks the values up automatically — no schema changes elsewhere.

- `dq_dashboard_url` (string). When set, the parent message renders an extra `*DQ dashboard*: <url|open>` line in its header and the status page renders a "DQ dashboard ↗" link in the per-config detail header. Use this for configs whose data has a dedicated DQ Looker Studio page that's better than the default anomaly-detection drill-in. Both links are kept — the new one does not replace the old.
- `text_inject` (string). Free-form Slack mrkdwn appended as the final line of the parent message. Subscribers paste raw mention tokens here (e.g. `cc <!subteam^SXXX>` for a subteam, `<@U…>` for an individual). The text is passed through unchanged — engineers writing the seed are responsible for valid mrkdwn. Only the parent carries the inject, so subscribers ping exactly once per `(config, anomaly_date)` incident, not on every state-transition reply. Not surfaced on the status page (mention tokens render as raw `<@…>` / `<!subteam^…>` garbage in HTML).

Both fields default to empty strings; configs that don't opt in render exactly as before. Update the seed CSV (one per env: `_dev`, `_staging`, `_prod`) and run `dbt seed` to ship a change. The renderer gates on a non-empty value after `.strip()`, so seed cleanup or a value-replacement is automatically reflected on the next alerter run.

### Un-bootstrapping a config

If you decide the bootstrapped anomalies are actually worth surfacing (e.g. they reveal a real long-running issue you want a thread for), delete the marker rows and the next alerter run will treat them as fresh:

```sql
DELETE FROM `world-fishing-827.tech_anomaly_detection.t_qa_gfw_anomaly_detection_alerting_dev_incidents`
WHERE config_name = '<your_config>'
  AND STARTS_WITH(slack_ts, 'BOOTSTRAP-');
```

Adjust the table name for `staging` / `prod` as needed. After deletion, `list_configs_with_any_incident` may still return the config (if other non-bootstrap rows exist for it), in which case the next run won't re-bootstrap — it'll just open real Slack threads for whatever historical anomalies are still in the deltas table's 30-day window.
