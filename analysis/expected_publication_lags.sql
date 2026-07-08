-- Derive expected_delay_hour per dataset for the t_expected_publication_lags
-- seed (monitoring repo: ci/executor/dbt/seeds/t_expected_publication_lags.csv).
--
-- Semantics (since 2026-07-08): expected_delay_hour = p90 of the last 120 days'
-- realized arrival delays. "Realized arrival delay" = first observation of a
-- date's data minus the START of that data day (timestamp_delay_minute in
-- v_scraped_api_values). The gfw_api_delays anomaly config alerts when data is
-- still missing once its age exceeds this baseline.
--
-- History: the seed originally used the all-time MINIMUM observed delay. That
-- was only workable because v_scraped_api_values anchored the hypothetical
-- (data-still-missing) delay at the END of the data day while realized delays
-- (and the seed) used the START -- a 24h mismatch that silently loosened every
-- alerting threshold by a day. With the anchors aligned (monitoring repo,
-- 2026-07-08), min-based seeds would alert on 20-99% of normal days for
-- wide-distribution datasets; p90 keeps alert volume at the historically
-- tolerated level while detecting genuine outages up to 24h earlier.
--
-- Detection is quantized by the dataloader's daily 10:20 UTC fetch: a date can
-- only be caught at the first fetch where its age exceeds seed+1h (constant
-- forecast 0.5 + critical_higher 1.0 => metric must exceed 1h). The
-- effective_bar_h / alert_rate columns below make that phase arithmetic
-- explicit. Review THOSE, not just the suggested seed value, before pasting
-- new values into the seed CSV: a seed whose bar lands just past a fetch
-- boundary can double a dataset's alert rate.
--
-- Notes:
--   * `timestamp_delay_minute` is only non-null when data was actually
--     observed, so the stats ignore still-missing dates.
--   * `date >= first_valid_from_date` excludes reference dates that predate
--     scraper coverage (backfill distortion).
--   * Datasets with no arrivals in the window keep their current seed value
--     and are flagged for manual review (dead or paused sources -- consider
--     removing the row instead; seed membership is the alerting opt-in).

WITH per_date AS (
  SELECT dataset, date, MIN(timestamp_delay_minute) AS arr_min
  FROM `world-fishing-827.tech_dq_monitoring.v_scraped_api_values`
  WHERE date_interval = 'DAY' AND environment = 'prod'
    AND timestamp_delay_minute IS NOT NULL
    AND date >= first_valid_from_date
  GROUP BY dataset, date
),
stats AS (
  SELECT
    dataset,
    COUNTIF(date >= DATE_SUB(CURRENT_DATE(), INTERVAL 120 DAY)) AS obs_120d,
    APPROX_QUANTILES(IF(date >= DATE_SUB(CURRENT_DATE(), INTERVAL 120 DAY), arr_min, NULL), 100)[OFFSET(90)] AS p90_min,
    ROUND(MIN(IF(date >= DATE_SUB(CURRENT_DATE(), INTERVAL 120 DAY), arr_min, NULL)) / 60, 0) AS min_120d_h,
    ROUND(APPROX_QUANTILES(IF(date >= DATE_SUB(CURRENT_DATE(), INTERVAL 120 DAY), arr_min, NULL), 100)[OFFSET(50)] / 60, 0) AS median_120d_h
  FROM per_date
  GROUP BY dataset
),
suggested AS (
  SELECT
    s.dataset,
    s.environment,
    s.expected_delay_hour AS current_seed_h,
    st.obs_120d,
    st.min_120d_h,
    st.median_120d_h,
    CAST(COALESCE(ROUND(st.p90_min / 60), s.expected_delay_hour) AS INT64) AS suggested_seed_h
  FROM `world-fishing-827.tech_dq_monitoring.t_expected_publication_lags` s
  LEFT JOIN stats st USING (dataset)
),
with_bar AS (
  -- first 10:20 UTC fetch age (minutes after start-of-day anchor) exceeding seed+1h
  SELECT
    *,
    (620 + 1440 * CAST(CEIL(((suggested_seed_h + 1) * 60 - 620) / 1440.0) AS INT64)) / 60.0 AS effective_bar_h
  FROM suggested
)
SELECT
  w.dataset,
  w.environment,
  w.current_seed_h,
  w.suggested_seed_h,
  CAST(CEIL(w.suggested_seed_h / 24) AS INT64) AS suggested_seed_day,
  w.min_120d_h,
  w.median_120d_h,
  w.obs_120d,
  ROUND(w.effective_bar_h, 1) AS effective_bar_h,
  ROUND(SAFE_DIVIDE(COUNTIF(p.arr_min > w.effective_bar_h * 60), COUNT(p.date)) * 100, 1) AS alert_rate_pct_120d,
  CASE
    WHEN w.obs_120d IS NULL OR w.obs_120d = 0 THEN 'NO_RECENT_DATA'
    WHEN w.obs_120d < 30 THEN 'LOW_SAMPLE'
    ELSE 'OK'
  END AS flag
FROM with_bar w
LEFT JOIN per_date p
  ON p.dataset = w.dataset AND p.date >= DATE_SUB(CURRENT_DATE(), INTERVAL 120 DAY)
GROUP BY w.dataset, w.environment, w.current_seed_h, w.suggested_seed_h,
         w.min_120d_h, w.median_120d_h, w.obs_120d, w.effective_bar_h
ORDER BY flag DESC, w.dataset;
