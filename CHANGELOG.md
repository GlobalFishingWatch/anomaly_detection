# Changelog

Notable changes to this repo. Entries are organised by component and listed newest-first.

## Alerting

### Unreleased (v2.1 on `dev`)

- Per-config aggregation modes (`flat`, `flat-with-resolve-replies`, `thread`) via a post-filter at the end of `state.process_thread`. Configs without a `dimension_split` no longer produce opener+fire+summary thread clutter; the opener itself renders as a rich fire card. Thread mode is the v2 behaviour and remains the default.
- Severity-aware opener emoji. `OpenThread` carries the aggregate severity (`critical` / `warning` / `normal`) derived from the initial fire batch; `render_thread_opener` picks `:red_circle:` / `:large_yellow_circle:` / `:large_green_circle:`. The static `:rotating_light:` is gone.
- Duplicate-thread guard. `find_open_incident` now also returns incidents with `status='resolved'` whose `closed_at` is within the last 24h. `main.run` flips such a row back to `status='open'` (clearing `closed_at`) when a fresh anomaly appears for the same `(config, anomaly_date)`, so replies land in the existing Slack thread instead of opening a duplicate. Past 24h a fresh thread is accepted.
- No schema changes.

### v2 (`56d2d25` on `dev`, 2026-04-23)

- Thread identity = `(config_name, DATE(timestamp))`. Separate Slack threads per data-date; hourly configs collapse into one thread per day.
- Replies are append-only (no `chat.update`). Every state transition posts a new reply; the thread is the timeline. Summary reply is debounced to at most one per thread per run.
- `t_alerting_incident_replies` restructured to an append-only event log keyed on `(incident_slack_ts, dim, method)`; `insert_reply_event` only ever inserts.
- `t_alerting_incidents` gained `anomaly_date` and `summary_counts_json` (for debouncing).
- Thread closure: all-resolved or 7-day hard cap (no inactivity timeout).

### Earlier v1 / v0 work

Pre-v2 the alerter sent one Slack notification per anomaly row, keyed on a deduplication index. See `git log` before `56d2d25` for details.
