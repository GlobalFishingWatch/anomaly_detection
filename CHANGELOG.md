# Changelog

Notable changes to this repo. Entries are organised by component and listed newest-first.

## Alerting

### Unreleased (v2.2 on `dev`)

- `make_looker_studio_url` rewritten to match what the dashboard's apply-filters action emits: compact JSON (no spaces between keys/values), `:` and `,` left unencoded in the query string, and two extra `df34` / `df43` data-source filter params alongside the existing `PARAM_*` variables. Without those filters the deep-link opened a report with parameter values set but no rows actually filtered. Domain switched from `lookerstudio.google.com` to `datastudio.google.com/u/0` to mirror the canonical UI form. Format locked in with a byte-for-byte fixture test.
- Per-config `dq_dashboard_url` (optional). Direct deep-link to a config-specific page in the team's separate "DQ Dashboard" Looker Studio report. Surfaces as a header line in the parent message ("DQ dashboard | open") and as a link badge on the status page detail header. Source: new column on the `config_descriptions_<env>` dbt seed; configs that don't opt in render unchanged.
- Per-config `text_inject` (optional). Free-form Slack mrkdwn snippet appended to the parent message. Designed for "subscribing" specific people/subteams to a config via raw mention tokens (`<@U…>`, `<!subteam^S…>`); the renderer pastes it through unchanged. Only attached to the parent — never repeated on per-fire / severity / resolve replies, so subscribers ping exactly once per `(config, anomaly_date)` incident. Slack-only; the status page does not surface this field (mention tokens render as raw garbage in HTML).
- Thread-mode parent embeds a frozen-at-open counts table so channel scanning doesn't require opening the thread. Parent is still written once (no `chat.update`); count changes between runs continue to post as in-thread summary replies.
- Redundant initial `PostSummary` reply suppressed — the parent itself is the opening snapshot.
- Opener bugfix: thread-mode parents no longer duplicate the first fire card (was a v2.1 regression — `OpenThread.first_fire_row` was populated unconditionally).

### v2.1 (`8ee3aa9` on `dev`, 2026-04-24)

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

## DBT

### Unreleased (on `dev`)

- Cloud Build automation for `dbt seed`. New triggers in `dbt/cloudbuild/main.tf` fire on changes under `dbt/**`: branch trigger maps `dev`/`main` to `DBT_ENVIRONMENT=dev`/`staging` (other branches no-op); tag trigger reseeds prod. Steps run inside `ghcr.io/dbt-labs/dbt-bigquery:1.8.1` (matches the local `dbt-core==1.8.1` install — no `pip install` step). The trigger runs as `terraform-deployer@world-fishing-827.iam.gserviceaccount.com`, which already has dataset-level `WRITER` on `tech_anomaly_detection` — no extra IAM grant needed. Local override path documented in `dbt/README.md` and templated by the new `dbt/profiles.yml.example`.

## Dataloader

### Unreleased (on `dev`)

- Retry `refresh_deltas_table` on the BigQuery "another truncation operation in progress" error. Each dataloader container ends with `CREATE OR REPLACE TABLE t_{env}_deltas` via `t_deltas.sql`, so when several Cloud Run executions finish in the same window BQ rejects all but one with that exact error; the losers were previously crashing the container. The refresh is now wrapped in a 5-attempt loop with jittered linear backoff (10–60s waits) targeting only that error string. Other failures (auth, syntax, allowed_size) still propagate immediately. Was firing 1–6× per day on the dev cron.
- Fix logger crash that silently disabled the four `parsed_row_count_*_daily` configs since 2025-07-10 (`9258410`). The `log_info(list(current_anomaly_detection_config))` config dump in `forecast.R` was processed by `formatter_glue`, which tried to evaluate `{missing_timestamps_sql}`/`{existing_timestamps_sql}` placeholders embedded in `source_sql` before those variables were defined further down the file. The dump is now rendered with `str()` and brace-escaped before logging, which is robust against any future config that puts `{...}` in `source_sql`/`source_filter_sql`.
