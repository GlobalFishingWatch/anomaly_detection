-- Verify that min delays are consistent across scraper environments
-- (prod vs staging). If true, a single t_expected_publication_lags seed
-- applies across environments. If false, environment-specific seeds would
-- be required.
--
-- Expected result: for every dataset present in both environments, prod_min_h
-- equals staging_min_h. Datasets with only one environment get NULL on the
-- other side.

WITH by_env AS (
  SELECT
    dataset,
    environment,
    COUNT(*) AS obs,
    ROUND(MIN(timestamp_delay_hour), 0) AS min_h,
    ROUND(APPROX_QUANTILES(timestamp_delay_hour, 2)[OFFSET(1)], 0) AS median_h
  FROM `world-fishing-827.tech_dq_monitoring.v_scraped_api_values`
  WHERE date_interval = 'DAY'
    AND timestamp_delay_hour IS NOT NULL
    AND date >= first_valid_from_date
  GROUP BY dataset, environment
)
SELECT
  dataset,
  COUNTIF(environment = 'prod') > 0 AS in_prod,
  COUNTIF(environment = 'staging') > 0 AS in_staging,
  MAX(IF(environment = 'prod', min_h, NULL)) AS prod_min_h,
  MAX(IF(environment = 'staging', min_h, NULL)) AS staging_min_h,
  MAX(IF(environment = 'prod', median_h, NULL)) AS prod_median_h,
  MAX(IF(environment = 'staging', median_h, NULL)) AS staging_median_h
FROM by_env
GROUP BY dataset
ORDER BY dataset;
