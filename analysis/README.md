# Analysis

Ad-hoc SQL used to derive configuration values for anomaly detection configs
from the observed behaviour of the underlying data sources.

## expected_publication_lags.sql

Derives per-dataset expected publication delays for the
`t_expected_publication_lags` seed in the monitoring repo
(`monitoring/ci/executor/dbt/seeds/t_expected_publication_lags.csv`).

### What it does

For every dataset observed in `tech_dq_monitoring.v_scraped_api_values`,
compute summary stats of `timestamp_delay_hour` (the actual observed delay
between a data reference date and when the scraper first saw that data).

The `MIN(timestamp_delay_hour)` value is used as the suggested
`expected_delay_hour` for the seed. This follows the semantics documented in
the `gfw_api_delays` config description: *"The expected publication time is
the minimum delay based on all historical publications."*

The query filters `date >= first_valid_from_date` per dataset to exclude
reference dates that predate when the scraper started observing that dataset
(otherwise backfill observations inflate the distribution).

### Why the seed matters

The `gfw_api_delays` anomaly detection config monitors
`timestamp_delay_hour_now_hypothetical`, the elapsed time since end-of-day
for reference dates where data has not yet been published. Without an
expected delay baseline, every dataset with a non-trivial publication cycle
(e.g., 4-day private VMS pipelines) trips the constant threshold every day.

Once `t_expected_publication_lags` is populated for all monitored datasets,
the source view computes the corrected column
`timestamp_delay_now_hypothetical_vs_expected_delay_hour`, which is the
intended metric: hours late relative to the expected publication time.
The anomaly detection config can then monitor that column with a much
tighter threshold (near zero), producing alerts only when data is
genuinely late.

### Flag interpretation

| flag | meaning |
|------|---------|
| `OK` | Enough observations, recent activity, plausible delay. Use `expected_delay_hour_suggested` as-is. |
| `INSUFFICIENT_DATA` | <30 observations since the scraper started. Treat the suggestion with caution. |
| `NO_RECENT_DATA` | No observations in the last 90 days. Pipeline likely stalled or dataset is obsolete -- investigate before seeding. |
| `LIKELY_OBSOLETE` | Min delay exceeds 14 days. The dataset has never published quickly; likely retired. Do not seed -- consider removing from monitoring. |
| `LONG_STABLE_CYCLE` | Min equals median and both exceed 7 days. Looks like a genuine slow-but-consistent publication schedule. Seed with the observed value. |

## environment_comparison.sql

Sanity check: confirms that min delays are identical across scraper
environments (prod vs staging), so a single seed works across environments.
Staging only contains a subset of datasets (~22) that also exist in prod
(~101); their min delays match. Running the check before updating the seed
guards against the case where production and staging diverge.

## How to re-run

```
bq query --project_id=world-fishing-827 --use_legacy_sql=false \
  --format=pretty --max_rows=200 < expected_publication_lags.sql
```

Default BQ execution project is `world-fishing-827`.
