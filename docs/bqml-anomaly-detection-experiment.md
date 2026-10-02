# BigQuery ML as the modelling engine: pricing and experiment

Date: 2026-10-02. Purpose: establish what BigQuery ML (ARIMA_PLUS +
`ML.DETECT_ANOMALIES`) costs at our data volumes and how it behaves on a
real anomaly, as input to scenario C in
[architecture-scenarios.md](architecture-scenarios.md).

## Pricing facts (first-party, BigQuery pricing page and references)

- On-demand pricing is per bytes processed by the training query's input
  `SELECT`, not table size and not training time.
- Time series model creation (ARIMA_PLUS): $312.50 per TiB. Shared with
  linear/logistic regression, k-means, PCA, contribution analysis.
- For ARIMA_PLUS the input bytes are multiplied by the number of auto.ARIMA
  candidate models: 6 at the default `AUTO_ARIMA_MAX_ORDER = 2`, up to 21 at
  order 5.
- Minimum 10 MB billed per query and per table referenced; rounded up to
  the MB.
- Evaluation, inspection and prediction (`ML.FORECAST`,
  `ML.DETECT_ANOMALIES`, `ML.ARIMA_EVALUATE`): $6.25 per TiB, inside the
  1 TiB per month analysis free tier. No free tier was found for
  `CREATE MODEL`.
- Under editions, built-in model training consumes slots from the QUERY
  reservation; BigQuery ML is not available in the Standard edition.
- Models are stored at normal storage rates (kilobytes).

## Our data volumes (`t_dev_actuals`, latest rows, 2026-10-02)

| | Rows | Training input |
|---|---|---|
| Whole table, 18 configs | 268k | 117 MB logical; ~9 MB as (timestamp, value, dim) |
| Largest config (hourly product events, 5.4 years) | 129k | ~5 MB |
| Typical daily config (4 years x up to 20 dims) | 4k-30k | 0.2-1.2 MB |

## Measured training cost

Two ARIMA_PLUS trainings of `parsed_row_count_receiver_type_daily`
(3 series, ~1,450 daily points each) billed **104,857,600 bytes (100 MiB)
each, about $0.03**. The input `SELECT` scanned the unpartitioned actuals
table rather than the 10 MB floor, times 6 candidates. Implications:

| Training shape | Today (18 configs) | 10x (180) |
|---|---|---|
| One model per config, daily | ~$16 /month | ~$160 /month |
| One model per config, weekly | ~$2.3 /month | ~$23 /month |
| One model per frequency class (daily, hourly) over all dims via `TIME_SERIES_ID_COL`, daily | ~$1 /month | ~$10 /month |

Partitioning or pre-filtering the actuals so the input `SELECT` scans only
the relevant config would bring per-config trainings down to the 10 MB
floor (~$0.02). Detection queries round to zero.

## What `ML.DETECT_ANOMALIES` is

- One parameter for time-series models: `anomaly_prob_threshold`, default
  0.95, range [0, 1). It sets both the flag cut-off and the band width (a
  larger value widens the interval).
- Two modes. Historical: no input; detects anomalies inside the training
  data; requires `DECOMPOSE_TIME_SERIES = TRUE`. New data: pass a table or
  query whose columns match training; the model forecasts those timestamps
  from the end of its training data and compares.
- The probability is computed from the actual value, the predicted value
  and the variance learned in training.
- Everything else is a `CREATE MODEL` option: `AUTO_ARIMA` order bounds,
  `DATA_FREQUENCY` (`AUTO_FREQUENCY`, `PER_MINUTE`, `HOURLY`, `DAILY`,
  `WEEKLY`, `MONTHLY`, `QUARTERLY`, `YEARLY`), `HOLIDAY_REGION`,
  `CLEAN_SPIKES_AND_DIPS` (default TRUE), `ADJUST_STEP_CHANGES` (default
  TRUE), `TIME_SERIES_LENGTH_FRACTION`, `MIN/MAX_TIME_SERIES_LENGTH`,
  `TREND_SMOOTHING_WINDOW_SIZE`, `INCLUDE_DRIFT`, `FORECAST_LIMIT_*`,
  `HORIZON`, `DECOMPOSE_TIME_SERIES`. `TIME_SERIES_ID_COL` scales to
  100 million series per query.
- There is no warm-start or state-update option for ARIMA_PLUS. Retraining
  is the only way to obtain one-step-ahead bands.

## Experiment

Target: the satellite receiver-type drop of 2026-09-16 to 2026-09-21
(daily parsed rows fell from ~24-28M to 13.4M on Sep 19-20). Two models
trained in `scratch_christian_homberg_ttl120d` (120-day TTL; the
`dq-monitoring@` impersonation lacks `bigquery.models.create` there, so
training ran as the personal user):

```sql
CREATE OR REPLACE MODEL `world-fishing-827.scratch_christian_homberg_ttl120d.arima_receiver_type_cut_20260815`
OPTIONS (model_type = 'ARIMA_PLUS',
         time_series_timestamp_col = 'timestamp',
         time_series_data_col = 'value',
         time_series_id_col = 'dimension_split_value',
         data_frequency = 'DAILY',
         decompose_time_series = TRUE,
         horizon = 90) AS
SELECT timestamp, value, dimension_split_value
FROM `world-fishing-827.tech_anomaly_detection.t_dev_actuals`
WHERE config_name = 'parsed_row_count_receiver_type_daily'
  AND is_latest
  AND DATE(timestamp) < '2026-08-15';
-- second model: same, cutoff '2026-09-30', suffix _20260930
```

```sql
-- what the model chose per series
SELECT dimension_split_value, non_seasonal_p, non_seasonal_d, non_seasonal_q,
       has_spikes_and_dips, has_step_changes, seasonal_periods
FROM ML.ARIMA_EVALUATE(MODEL `...arima_receiver_type_cut_20260815`);

-- new-data detection from the Aug-15 model
SELECT DATE(timestamp) AS dt, value, lower_bound, upper_bound, is_anomaly, anomaly_probability
FROM ML.DETECT_ANOMALIES(
  MODEL `...arima_receiver_type_cut_20260815`,
  STRUCT(0.95 AS anomaly_prob_threshold),
  (SELECT timestamp, value, dimension_split_value
   FROM `world-fishing-827.tech_anomaly_detection.t_dev_actuals`
   WHERE config_name = 'parsed_row_count_receiver_type_daily' AND is_latest
     AND DATE(timestamp) >= '2026-08-15'));

-- historical (in-sample) detection: no input argument
SELECT * FROM ML.DETECT_ANOMALIES(MODEL `...arima_receiver_type_cut_20260930`,
                                  STRUCT(0.95 AS anomaly_prob_threshold));
```

### Model selection

| Series | ARIMA (p,d,q) | Spikes/dips | Step changes | Seasonal periods |
|---|---|---|---|---|
| dynamic | 2,1,0 | yes | yes | WEEKLY, YEARLY |
| satellite | 1,1,1 | yes | yes | WEEKLY |
| terrestrial | 0,1,2 | yes | yes | WEEKLY |

Step-change detection is the mechanism MSTL lacks for these series (see
"Our own system" below).

### Band width vs horizon (satellite, Aug-15 model, threshold 0.95)

| h (days after cutoff) | 1 | 2 | 3 | 7 | 14 | 30 | 45 |
|---|---|---|---|---|---|---|---|
| band width, % of actual | 29 | 34 | 37 | 44 | 39 | 44 | 45 |

Bands widen quickly in the first week, then plateau around 45%; the
absolute interval settles at ~12M wide from h >= 7 versus ~5.8M at h = 1.

### Detection by the stale (Aug-15) model, h = 32-38

| Date | Actual (M) | Bounds (M) | Flagged | p |
|---|---|---|---|---|
| 09-16 | 20.3 | 17.3-29.0 | no | 0.66 |
| 09-17 | 19.5 | 17.1-29.0 | no | 0.76 |
| 09-18 | 17.0 | 17.4-29.3 | yes | 0.96 |
| 09-19 | 13.4 | 17.6-29.7 | yes | 0.999 |
| 09-20 | 13.4 | 17.9-30.0 | yes | 0.999 |
| 09-21 | 17.3 | 17.6-29.8 | yes | 0.96 |

The real event was caught five weeks after training; the mild onset was
not. The stale model's larger failure was elsewhere: terrestrial shifted
level right after the cutoff (~980M vs an expected ~1,110M) and was
flagged every day from 08-15 for 16+ days. `ADJUST_STEP_CHANGES` acts only
at training time, so a model that is not retrained cannot absorb a new
level and alarms indefinitely. This, not band width, is the decisive
argument for daily retraining.

### One-step model (trained through Sep 29) vs stale model on 2026-09-30

| dim | actual (M) | h=1 band (0.95) | flagged | h=46 band | flagged |
|---|---|---|---|---|---|
| dynamic | 351.4 | 368.1-398.0 (9%) | yes | 222.7-397.9 (50%) | no |
| satellite | 28.7 | 25.5-31.4 (20%) | no | 16.6-29.6 (45%) | no |
| terrestrial | 993.8 | 947.9-972.9 (3%) | yes | 1044.5-1253.6 (21%) | yes |

Both one-step flags are false positives: 351 and 994 are ordinary values
in their recent ranges (dynamic 344-359, terrestrial 938-1011 over the
prior week). The ARIMA trend extrapolated a recent swing and the 3-9% band
is over-confident after a volatile stretch. Threshold 0.99 widened the
bands only marginally (3% -> 3%, 9% -> 11%) and changed no verdict.

### Historical (in-sample) mode, Sep-30 model, satellite

Flags the transitions (Sep 16, 18, 19 down; Sep 22, 23, 26 up) and within
about three days accepts the lower level as normal (band on Sep 20:
12.7-18.6M). A sustained shift is treated as a regime change.

## Findings

1. Retrain daily. Cost is ~3 cents per training; the benefit is 2-7x
   tighter bands and, more importantly, absorption of level shifts that a
   stale model alarms on indefinitely.
2. Do not use `is_anomaly` as the alert signal. The probability threshold
   is not a calibration knob comparable to our relative-delta thresholds,
   and one-step intervals can be over-confident after volatility. Use
   `ML.FORECAST` at h = 1 as `forecast_value` and keep the deltas and
   thresholds layer on top (optionally AND both signals).
3. Decide regime-change semantics consciously. ARIMA_PLUS auto-resolves a
   sustained drop within days, which suits genuine level shifts (satellite
   volume halved earlier in 2026) but silences a persistent outage unless
   the thresholds layer or the liveness configs keep it open. MSTL does
   the opposite and never adapts.
4. Seasonality detection is automatic and matched expectations (weekly
   everywhere, yearly where present).

## Our own system, same event

`t_dev_deltas` for satellite, 2026-09-14 to 09-24, method `mstl`:
forecasts of 41-57M against actuals of 13-28M, `delta_rel` -0.45 to -0.70
every day, `critical_lower` and `warning_lower` NULL, `anomaly_type`
"normal". Two separate facts:

- The MSTL forecast never adapted to the series halving months earlier; it
  would fire critical daily if it could.
- It cannot: thresholds are joined per `(config_name, forecast_method)` and
  `thresholds_dev.csv` has only a `mean` row for this config, so the MSTL
  and median forecasts are computed but can never alert. Only `mean`
  flagged the drop (warning from 09-16, critical on 09-19/20).

Decision needed regardless of BigQuery ML: seed a thresholds row for every
method a config runs, or stop computing forecasts that cannot fire.
Tracked in `ROADMAP.md`.

## Caveats

One config, three series, one event, one threshold. The one-step false
positives and the plateauing band width are observations, not laws; a
proper evaluation would backtest several configs over months against the
alerter's actual incidents. The models and scratch artifacts expire after
120 days.

## Sources

- BigQuery pricing (BigQuery ML section): https://cloud.google.com/bigquery/pricing
- CREATE MODEL for ARIMA_PLUS: https://docs.cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-create-time-series
- ML.DETECT_ANOMALIES: https://docs.cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-detect-anomalies
