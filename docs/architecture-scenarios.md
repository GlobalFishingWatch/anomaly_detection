# Architecture scenarios: dbt, R, BigQuery ML, Python

Companion to [2026-10-tooling-evaluation.md](2026-10-tooling-evaluation.md).
That document concludes no vendor; this one lays out how the in-house
pieces could be recombined. Status: proposal, not decided.

## The principle: the deltas table is the API

The alerter reads `t_<env>_deltas` and nothing else. A row needs a config
name, dimension, timestamp, actual, forecast, thresholds and the derived
anomaly type. Any engine that writes rows in that shape gets the threaded
Slack lifecycle, bootstrap suppression, silencing, routing and mentions for
free. Mix-and-match is therefore a per-config-class choice of engine, not a
rewrite, and the alerter stays constant through every scenario below.

## Layers and classes

| Layer | Today | Candidates |
|---|---|---|
| Extraction | R, per-config SQL + SCD2 | dbt incremental models |
| Modelling | R: MSTL (365.25 + 7), mean/median, constant | BigQuery ML ARIMA_PLUS; R kept for bespoke cases |
| Classification | `t_deltas.sql` run by R | dbt model (it is already pure SQL) |
| Incident / Slack | Python alerter v2 | unchanged |
| Job health | none | GCP-native alerting; selective Sentry Crons |

Config classes and what each actually needs are tabulated in the tooling
evaluation; roughly half the configs need no model at all (delays, cost
thresholds, ratios) and half need multi-seasonal modelling.

## Scenarios

**A. Delays out of the dataloader, into dbt.** The scraped-values view
already computes the delay. A dbt model with the seeded expected lag and
threshold writes deltas-shaped rows, evaluated hourly by an existing dbt
Cloud Run job. This removes `refetch_recent_days`, the anchor arithmetic
and the fetch-phase problem for that class, because an hourly-evaluated
freshness gauge is the right model for it. Open decision: which repo's dbt
project owns these models (leaning: this repo's, reading the monitoring
views, so ownership stays with the alerting config).

**B. dbt takes extraction and classification; R keeps only modelling.**
Per-config source SQL becomes incremental dbt models producing the actuals
tables; `t_deltas.sql` becomes a dbt model; `forecast.R` shrinks to "read
actuals, write forecasts". Guardrails move to dbt billing tiers. Cost:
orchestration (dbt, then R, then dbt) replaces per-config schedulers. Gain:
one dbt run covers every config, which is what makes 10x cheap to operate.

**C. BigQuery ML as the default modelling engine, R as the escape hatch.**
ARIMA_PLUS with auto-detected weekly and yearly seasonality, holidays, step
changes and spike cleaning, trained for cents, with `ML.FORECAST` at h=1
feeding `forecast_value`. R remains for configs that want bespoke models or
research-grade methods; its maintenance cost is confined to configs that
earn it. Findings and caveats in the BQML experiment document, in
particular: retrain daily (one-step bands are 2-7x tighter and a stale model
cannot absorb level shifts), keep our thresholds layer rather than using
`is_anomaly` as the alert signal, and decide consciously how step-change
adaptation should interact with incident resolution.

**D. Elementary for the simplest volume configs.** Viable but not
recommended unless it also replaced the alerter, which it should not.

**E. Job health as its own layer.** GCP-native alerting on Cloud Run job
execution failures and Scheduler misses, independent of all the above.

## Sequencing

1. A, immediately: most complexity removed for least work; fixes detection
   latency for the delay class.
2. E alongside it.
3. B when the per-config scheduler fleet starts to hurt (it will at 5x).
4. C once B exists, config by config, R retained where justified.

Each step is independently valuable and reversible because the deltas
contract and the alerter never change. End state: dbt for extraction,
classification and the delay class; BigQuery ML for most seasonal
modelling; R only where sophistication pays; the Python alerter as the
single incident layer; per-config cost measured in query bytes.

## Prerequisite fix regardless of scenario

Thresholds are joined per `(config_name, forecast_method)`
(`t_deltas.sql`: `LEFT JOIN t_thresholds_{ENVIRONMENT} USING(config_name,
forecast_method)`). A config whose seed only has a `mean` row therefore
computes MSTL and median forecasts that can never fire. Either seed a row
per method a config runs, or stop computing forecasts that cannot alert.
See the experiment document for the concrete case.
