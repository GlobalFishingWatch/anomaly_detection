-- Derive expected_delay_hour per dataset for the t_expected_publication_lags seed.
--
-- Purpose: the gfw_api_delays anomaly config needs a per-dataset baseline of how
-- long after a reference date data normally becomes available. We use the
-- minimum observed delay (fastest historical publication) as the baseline,
-- following the same semantics the config_descriptions states:
--   "The expected publication time is the minimum delay based on all
--    historical publications."
--
-- Notes:
--   * `timestamp_delay_hour` is only non-null when data was actually observed,
--     so MIN captures the best-case publication time regardless of backfills.
--   * We filter `date >= first_valid_from_date` to exclude data reference dates
--     that predate when the scraper started observing that dataset (otherwise
--     percentile stats are inflated by backfills at scraper startup).
--   * Min values are identical across scraper environments (prod vs staging)
--     for shared datasets, so no environment split is needed.
--   * Datasets with very few observations (<30 in the window) or no recent
--     observations are flagged in the output for manual review.

WITH per_dataset AS (
  SELECT
    dataset,
    MIN(first_valid_from_date) AS scraper_started,
    COUNT(*) AS obs,
    COUNTIF(date >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)) AS obs_last_90d,
    ROUND(MIN(timestamp_delay_hour), 0) AS min_h,
    ROUND(APPROX_QUANTILES(timestamp_delay_hour, 20)[OFFSET(1)], 0) AS p5_h,
    ROUND(APPROX_QUANTILES(timestamp_delay_hour, 10)[OFFSET(1)], 0) AS p10_h,
    ROUND(APPROX_QUANTILES(timestamp_delay_hour, 4)[OFFSET(1)], 0) AS p25_h,
    ROUND(APPROX_QUANTILES(timestamp_delay_hour, 2)[OFFSET(1)], 0) AS median_h,
    ROUND(MAX(timestamp_delay_hour), 0) AS max_h
  FROM `world-fishing-827.tech_dq_monitoring.v_scraped_api_values`
  WHERE date_interval = 'DAY'
    AND timestamp_delay_hour IS NOT NULL
    AND date >= first_valid_from_date
  GROUP BY dataset
)
SELECT
  dataset,
  scraper_started,
  obs,
  obs_last_90d,
  min_h AS expected_delay_hour_suggested,
  CEIL(min_h / 24) AS expected_delay_day_suggested,
  p5_h,
  p10_h,
  p25_h,
  median_h,
  max_h,
  CASE
    WHEN obs < 30 THEN 'INSUFFICIENT_DATA'
    WHEN obs_last_90d = 0 THEN 'NO_RECENT_DATA'
    WHEN min_h > 24 * 14 THEN 'LIKELY_OBSOLETE'
    WHEN min_h = median_h AND min_h > 24 * 7 THEN 'LONG_STABLE_CYCLE'
    ELSE 'OK'
  END AS flag
FROM per_dataset
ORDER BY dataset;
