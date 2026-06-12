# Alerting v2.1: flat mode + severity-aware opener + duplicate-thread guard

Deferred work from the v2 dev soak. Three targeted changes plus one optional
reconciliation.

## Context

v2 ships a uniform "(config, anomaly_date) thread with opener + per-dim fires
+ debounced summary reply" model for every config. The dev soak surfaced
three issues:

1. For configs without a `dimension_split` AND only one anomaly possible
   per day (most daily scalar configs), the thread structure is pure
   overhead. A single rich top-level alert is enough.
2. The opener emoji is always `:rotating_light:` and carries no aggregate
   information, so scanning the channel listing cannot distinguish
   critical from warning threads without opening each one.
3. If a (config, date) thread closes (all resolved) and a new anomaly
   appears for the same date later, a duplicate thread is opened for the
   same (config, date) because `find_open_incident` only looks at
   `status='open'`.

A fourth issue is known and lower priority:

4. `insert_reply_event` + `update_incident` are not transactional; a
   partial failure lets `summary_counts_json` drift from the event log.

## Config taxonomy driving item 1

Based on combined dimension_split + period_length analysis:

- **flat** (opener IS the alert; no fires, no summary reply):
  `parser_errors_daily`, `pipe3_gaps`,
  `pipe3_vs_pipe2_5_published_fishing_effort_deltas`,
  `pipe3_vs_pipe2_5_published_fishing_events_deltas`,
  `pipe3_vs_pipe2_5_published_fishing_events_duration_deltas`,
  `t_world_fishing_827_queries_billed`, `s2_index_delays`,
  `s2_published_detections_delays`, `pipe3_product_events_fishing_count_esp`
- **flat-with-resolve-replies** (opener carries the initial alert;
  severity changes and resolve still post as replies):
  `parsed_row_count_hourly`, `pipe3_product_events_fishing_count`
- **thread** (current v2 behaviour):
  `parser_errors_daily_by_source`, the four
  `parsed_row_count_*_daily` variants, `v_world_fishing_827_queries_billed_by_sa_non_sa`,
  `gfw_api_delays`

Decision rule: `dimension_split` present -> thread. No dim_split and daily
-> flat. No dim_split and hourly -> flat-with-resolve-replies.

## Design decisions

### 1. Flat mode via post-filter, not a second state machine

Keep `state.process_thread()` as the single decision surface. After it
computes actions, a small `_filter_for_flat_mode()` function drops action
types that aren't useful for that config's aggregation mode. The opener
rendering function receives the row details directly in flat mode so the
opener itself is the rich alert.

Mode is looked up by a hard-coded dict keyed on `config_name`. If the
dict grows unwieldy later, promote it to a column in the channel-mapping
seed.

Per-mode action set:

| Mode | Actions kept |
|------|--------------|
| thread | OpenThread, PostFire, PostSeverityChange, PostResolve, PostSummary, CloseThread |
| flat-with-resolve-replies | OpenThread, PostSeverityChange, PostResolve, CloseThread |
| flat | OpenThread, CloseThread |

For flat and flat-with-resolve-replies, `OpenThread` carries the first
firing row's details (current bucket, forecast, actual, delta_rel,
timestamp) so the opener itself renders as a fire card.

### 2. Severity-aware opener

Compute `max_severity_so_far` from the batch of fire rows before emitting
`OpenThread`, pass it into the `OpenThread` action, and have
`render_thread_opener` pick the emoji:

- any `critical_*` -> `:red_circle:`
- any `warning_*` -> `:large_yellow_circle:`
- otherwise (resolved / never-anomalous) -> `:large_green_circle:`

The opener is still written once and never edited. An escalation from
warning to critical after thread open is announced via the
`PostSeverityChange` reply (which users already see in the thread) and
reflected in the next `PostSummary`. Channel-scanner UX is not perfect
on that path but good enough; we explicitly rejected `chat.update` on
the parent as too much architectural drift for the benefit.

For flat-mode configs the opener rendering includes the full fire card
content, so the emoji plus in-body counts give scannable severity at a
glance without any further machinery.

### 3. Duplicate-thread guard

Extend `find_open_incident(config, anomaly_date)` with a second-stage
lookup: if no open incident found, query for the most recent
`status='resolved'` incident for that (config, anomaly_date) opened
within the last 24 hours. If found, treat it as still-open: reopen the
row (`status='open'`, `closed_at=NULL`) and return it. The state machine
then appends new reply events to the existing thread.

This keeps the Slack thread whole across resolve-then-reappear within a
day. After 24 hours we accept that a second thread would open for the
same (config, date) -- rare and harmless.

### 4. Summary-counts reconciliation (optional, defer)

At the top of `run()`, for each open incident, recompute the counts from
the event log and compare to `summary_counts_json`. On drift, update the
incident row silently (no new summary reply). Recovery is idempotent so
re-running the alerter multiple times converges.

Skip this for v2.1 unless we observe drift in practice; the cost is one
extra BQ read per open incident per run.

## Schema changes

None. Existing `t_alerting_incidents` and `t_alerting_incident_replies`
schemas cover everything. The duplicate-thread guard only changes query
predicates, not data shapes.

## Code changes

| File | Change |
|------|--------|
| `alerting/ci/executor/state.py` | Add `AGGREGATION_MODE` dict keyed on config_name; derive `max_severity_so_far` from initial fires; add `description` and optional fire-row details to `OpenThread` dataclass; add `_filter_for_flat_mode()` at the end of `process_thread()` |
| `alerting/ci/executor/slack.py` | Update `render_thread_opener` to accept severity + optional fire-row details; render a full fire card in flat mode; drop the static `:rotating_light:` |
| `alerting/ci/executor/bq.py` | Extend `find_open_incident` to reopen a recently-resolved incident within 24h |
| `alerting/ci/executor/main.py` | Pass severity + fire-row details into `OpenThread` creation path; handle the reopen path so the incident row transitions back to `status='open'` |
| `alerting/ci/executor/tests/test_state.py` | Add cases for each aggregation mode; add severity-emoji cases; add "reopen within 24h" scenario |

## Verification

1. Unit tests cover each mode's action shape for first-fire, severity
   change, resolve, close.
2. Replay fixture run with a flat config: verify ONE top-level message
   per (config, date), no reply clutter.
3. Replay fixture run with a thread config: verify the existing v2
   behaviour is preserved (opener + fires + summary).
4. Manually close an incident in BQ, re-insert a fresh anomalous delta
   row for the same (config, date), trigger the alerter, and confirm
   the thread reopens instead of duplicating.
5. Staging soak confirming the new emoji distribution matches what
   users expect in the channel listing.

## Estimated effort

1-2 engineer-days.
