# Off-the-shelf tooling evaluation (October 2026)

Question: could Datadog or Sentry replace or complement the two modules of
this repo (R dataloader incl. forecasting, Python alerter)? Extended to
Elementary (open source, dbt-native) and GCP-native options once the
budget was known.

Constraints that drove the decision:

- Budget: roughly $500/year for anomaly alerting, up to ~$1,000/year if job
  monitoring is included.
- Scale: the current 18 configs are a first-stage prototype; the intent is
  5-10x more configurations.
- Stack already in place: dbt (monitoring repo and this repo), Cloud Run
  jobs on Cloud Scheduler, BigQuery, Slack. Sentry subscription exists.

## Framing: three layers, one contract

The system is better described as layers than as two modules:

| Layer | Today | Nature |
|---|---|---|
| Extraction | `forecast.R` step 1: per-config BigQuery SQL producing daily series per dimension, delta loads, SCD2 history, `refetch_recent_days`, `deprecated_dims`, 60 GB cost guardrail | Config-driven SQL; the hard-won value |
| Modelling + classification | `forecast.R` step 2 (MSTL, mean/median, constant) + `t_deltas.sql` (thresholds, anomaly types, debouncing) | Forecasting; the only part that is "unlimited" in sophistication |
| Incident + notification | Python alerter v2: one Slack thread per (config, anomaly_date), fire/severity/resolve replies, bootstrap suppression, silencing, routing, mentions | The most commodity-like part |

The alerter reads only the deltas table. Anything that writes rows in that
shape gets the whole incident lifecycle for free, so the deltas table is
the integration contract and engines are pluggable behind it.

The 18 configs fall into classes with very different needs:

| Class | Configs | Needs |
|---|---|---|
| Freshness / delays | `gfw_api_delays`, `s2_index_delays`, `s2_published_detections_delays` | Seeded expected lag, static threshold, hourly evaluation; no model |
| Cost / ratio thresholds | queries-billed pair, `pipe3_vs_pipe2_5_*` (3) | Constant or sliding-window baseline; SQL-expressible |
| Seasonal volumes | `parsed_row_count_*` family, `parser_errors_*`, `pipe3_gaps`, product-events pair | Multi-seasonal modelling (weekly + yearly), hourly for two |

## Datadog

Two routes exist and they are priced differently.

**Route 1, custom metrics.** A thin job runs the existing config SQL and
emits each series as a custom metric; Datadog monitors replace modelling,
thresholds and the alerter. Verified capabilities and limits (Datadog docs):

- Anomaly monitors know only `hourly`, `daily`, `weekly` seasonality and use
  at most six weeks of history. The yearly-seasonal MSTL configs cannot be
  reproduced.
- Historical Metrics Ingestion exists (per-metric opt-in), so backfilling
  years of actuals is possible.
- Anomaly and forecast monitors are placed in the Enterprise tier on the
  pricing page.

**Route 2, Data Observability (Quality Monitoring) on BigQuery.** Native
table sync plus freshness, row-count, column and custom SQL monitors with
static thresholds or historical baselines; evaluation hourly or daily;
group-by with a default limit of 500 groups per monitor. Two billing facts
decide the shape (Datadog docs, verbatim): "Each Custom SQL monitor counts as
an individual monitored table for billing purposes", and standard monitors
on one table count once regardless of quantity. Our per-dimension series
live in long-format actuals tables, so reproducing a config requires a
Custom SQL monitor per config, i.e. the billing unit is "one per config",
not "one per table". Thresholds and model type are per monitor, not per
group, so even the grouped shape needs 3-5 monitors to cover today's
threshold classes.

### Pricing (first-party unless marked)

| Item | Price | Source |
|---|---|---|
| Infrastructure Pro / Enterprise | $15 / $23 per host per month annual; $18 / $27 on-demand; 100 / 200 custom metrics per host | pricing page |
| Free tier | up to 5 hosts, 1-day metric retention, basic alerts; no anomaly or forecast monitors | pricing page |
| Custom metrics overage | "billed based on usage" officially; ~$5 per 100 series per month | third-party |
| Custom metrics counting | monthly average of hourly distinct metric+tag combinations | custom metrics billing docs |
| Quality Monitoring | $16 per monitored table per month annual, $24 on-demand | Data Observability product page |

What a "host" is: any physical or virtual OS instance monitored, including
every cloud VM auto-discovered by a cloud integration. The GCP billing docs
state Datadog bills "all GCE instances picked up by the Google Cloud
integration" and that Dataflow "may create billable GCE hosts as a side
effect", at the 99th percentile of hourly host counts. For GFW's GCP estate
this is the trap; the mitigation is to never connect the production
projects and to use a dedicated monitoring project with no VMs.

### Cost at our scale

| Option | Today (18 configs) | 5x | 10x | Scales with |
|---|---|---|---|---|
| Quality Monitoring, Custom SQL grouped by env + dim, 3-5 monitors by threshold class | $576-960 /yr | $960-1,920 | $1,920-2,880 | monitors and groups |
| Custom metrics only, ~450 series | ~$180 /yr plus an Enterprise minimum | ~$900 | ~$1,800 | series |

Both are priced on the axis we intend to grow. Against the budget this is a
structural mismatch, not a negotiation problem.

### Open source programme

Programme terms (datadoghq.com/partner/open-source): projects must be
non-commercial under an approved licence, at least one year old with five
regular contributors, and "at least 2 maintainers need to work for different
companies". Scope clause, verbatim: "The infrastructure and applications
monitored and secured by Datadog need to be directly used to support the
project (i.e. instances of specific open source projects are out of scope
for the program)."

Reading: the programme funds infrastructure that exists for an open source
project (CI, docs, demo hosting), not deployments of a project and not an
organisation's production platform. GFW's production map deployment is an
instance of the frontend project; the data-quality pipeline supports GFW's
operations, not any project. The two-companies-of-maintainers rule is
designed to exclude single-organisation projects, and former staff who
contributed while employed do not make a project multi-vendor. Conclusion:
an honest application for the frontend project's own CI infrastructure is
harmless and may be granted; it would not cover this pipeline under any
reading. Applying under a framing that does not match actual usage would
rest on the reviewer not looking, for a discretionary programme that can be
revoked.

Datadog open-sources the Agent, tracers, SDKs and Vector and contributes to
OpenTelemetry; there is no self-hosted or community edition of the backend
and none of the anomaly or Data Observability logic is open.

## Sentry (subscription exists)

Sentry is an application-monitoring product; it has no warehouse-data or
time-series anomaly product aimed at this problem, so it cannot replace
either module. It fits the gap this repo demonstrably had: nobody watched
the watchers (four configs silently disabled for a year by a logger crash;
the staging alerter failing hourly for a year; cold-start failures; SIGKILL
timeouts). Cron Monitors do in-progress and heartbeat check-ins, detect
missed runs, failed runs and max-runtime overruns, with consecutive-failure
and recovery thresholds and per-monitor alert rules.

Pricing: one cron monitor included per plan, $0.78 per additional monitor
per month, pay-as-you-go only. One monitor per config schedule inherits the
same per-config scaling as the vendors above (~$300/yr today, ~$2,800/yr at
10x), so the recommendation is GCP-native alerting on Cloud Run execution
failures and Scheduler misses for the fleet (effectively free) and Sentry
Crons only for a handful of critical schedules such as the prod alerter
heartbeat.

## Elementary (open source, dbt-native)

Apache-2.0, BigQuery supported, runs as dbt tests; the OSS `edr monitor` CLI
posts Slack alerts. Capability mapping (Elementary docs):

| Our layer | Elementary OSS | Verdict |
|---|---|---|
| Per-dimension extraction | `dimension_anomalies` with `dimensions:` directly on the source table | Covers row-count and parser-error families without a dataloader |
| MSTL forecasts | z-score against a configurable `training_period`; seasonality limited to `day_of_week`, `hour_of_day`, `hour_of_week` | No yearly seasonality |
| Thresholds seed | `anomaly_sensitivity`, `anomaly_direction`, `ignore_small_changes`, `detection_delay` | Per test, in YAML |
| Deltas table | results stored in BigQuery tables | Looker-readable |
| Alerter | `edr monitor`, per-test channels, `--group-by table|alert` | Flat alerts, no incident lifecycle |
| Seeded delay configs | `freshness_anomalies` compares to a table's own history | Keep ours |

Zero licence cost; scales in query bytes. Not adopted for now because a
third engine with a different alerting style adds complexity without
replacing the alerter, whose incident model is better than flat
test-failure messages.

## Decision

No vendor for anomaly alerting. The in-house architecture is the only option
whose cost scales in query bytes rather than per config or per series, which
is the axis of planned growth. Job-health monitoring is added GCP-natively
with selective Sentry Crons. The modelling layer's future is evaluated in
[bqml-anomaly-detection-experiment.md](bqml-anomaly-detection-experiment.md);
the component split in [architecture-scenarios.md](architecture-scenarios.md).

## Sources

- Datadog pricing page: https://www.datadoghq.com/pricing/
- Datadog Data Observability product page (Quality Monitoring pricing): https://www.datadoghq.com/products/observability/data-observability/
- Datadog Data Observability monitors (Custom SQL billing note, group-by): https://docs.datadoghq.com/monitors/types/data_observability/
- Datadog anomaly monitors (seasonality, history): https://docs.datadoghq.com/monitors/types/anomaly/
- Datadog historical metrics ingestion: https://docs.datadoghq.com/metrics/custom_metrics/historical_metrics/
- Datadog custom metrics billing: https://docs.datadoghq.com/account_management/billing/custom_metrics
- Datadog Google Cloud integration billing: https://docs.datadoghq.com/account_management/billing/google_cloud/
- Datadog open source programme: https://www.datadoghq.com/partner/open-source/
- Sentry Crons pricing: https://sentry.zendesk.com/hc/en-us/articles/23058282687259-How-does-the-pricing-for-Crons-work
- Sentry Crons docs: https://docs.sentry.io/product/monitors-and-alerts/monitors/crons/
- Elementary docs: https://github.com/elementary-data/elementary (docs/data-tests, docs/oss)
