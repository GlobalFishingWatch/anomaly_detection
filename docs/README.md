# Design notes and evaluations

Longer-form material that does not belong in a component README. Operational
state lives in `ROADMAP.md`; the change history in `CHANGELOG.md`; working
rules for this codebase in `CLAUDE.md`.

| Document | What it covers | Status |
|---|---|---|
| [2026-10-tooling-evaluation.md](2026-10-tooling-evaluation.md) | Whether Datadog, Sentry, Elementary or GCP-native tooling could replace or complement the dataloader and alerter; pricing with sources; the Datadog open source programme; the decision | Decided: no vendor for anomaly alerting |
| [architecture-scenarios.md](architecture-scenarios.md) | The stack as four layers, the config classes we run, mix-and-match scenarios for dbt / R / BigQuery ML / Python, and the recommended sequencing | Proposal |
| [bqml-anomaly-detection-experiment.md](bqml-anomaly-detection-experiment.md) | BigQuery ML pricing facts, measured training cost, and an ARIMA_PLUS + `ML.DETECT_ANOMALIES` experiment on `parsed_row_count_receiver_type_daily` against the September 2026 satellite drop | Experiment, reproducible |

Conventions: dates in file names mark point-in-time evaluations (prices,
product features) that will go stale; undated files describe design
intent. Each document states which claims are first-party (vendor docs,
measured in BigQuery) and which are third-party or judgment calls.
