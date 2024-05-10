WITH
  all_partitions_non_empty AS (
    SELECT *
    FROM {{ ref('all_partitions') }}
    WHERE total_rows > 0
  ),
  all_partitions_with_ids AS (
    SELECT
      *,
      CONCAT(table_schema, ".", table_name) schema_table_name,
      CONCAT(table_schema, "-", table_name, "-", partition_id) id
      FROM all_partitions_non_empty
  ),
  all_partitions_last_modified_date AS (
    SELECT
      *,
      DATE(last_modified_time) last_modified_date,
      DATE(creation_time) creation_date,
      COUNT(DISTINCT last_modified_time) OVER (PARTITION BY schema_table_name) last_modified_count
    FROM all_partitions_with_ids
  ),
  all_partitions_safe_partition_id AS (
    SELECT *, CASE 
      WHEN (COUNT(*) OVER (PARTITION BY schema_table_name)) = 1 THEN NULL
      WHEN(partition_id = "__UNPARTITIONED__") THEN NULL
      WHEN(partition_id = "__NULL__") THEN NULL
      WHEN(partition_id IS NULL) THEN NULL
      ELSE partition_id END as safe_partition_id,
    FROM all_partitions_last_modified_date
  ),
  all_partitions_with_partitioning_info AS (
    SELECT 
      *,
      CASE
        WHEN (COUNT(*) OVER (PARTITION BY schema_table_name)) = 1 THEN "none"
        WHEN safe_partition_id IS NULL THEN NULL
        WHEN CHAR_LENGTH(safe_partition_id) = 6 THEN "monthly"
        WHEN CHAR_LENGTH(safe_partition_id) = 8 THEN "daily"
        WHEN CHAR_LENGTH(safe_partition_id) = 10 THEN "hourly"
        ELSE "unknown_partitioning"
      END AS partition_granularity
    FROM all_partitions_safe_partition_id
  ),
  all_partitions_with_partition_date AS (
    SELECT *, 
    CASE
      WHEN partition_granularity IS NULL THEN NULL
      WHEN partition_granularity = "monthly" THEN PARSE_DATE('%Y%m', safe_partition_id)
      WHEN partition_granularity = "daily" THEN PARSE_DATE('%Y%m%d', safe_partition_id)
      WHEN partition_granularity = "hourly" THEN DATE(PARSE_TIMESTAMP('%Y%m%d%H', safe_partition_id))
    END AS partition_date
    FROM all_partitions_with_partitioning_info
  ),
  all_partitions_with_partition_hour AS (
    SELECT *, 
    CASE
      WHEN partition_granularity IS NULL THEN NULL
      WHEN partition_granularity = "monthly" THEN TIMESTAMP(PARSE_DATE('%Y%m', safe_partition_id))
      WHEN partition_granularity = "daily" THEN TIMESTAMP(PARSE_DATE('%Y%m%d', safe_partition_id))
      WHEN partition_granularity = "hourly" THEN PARSE_TIMESTAMP('%Y%m%d%H', safe_partition_id)
    END AS partition_hour
    FROM all_partitions_with_partition_date
  ),
  all_partitions_with_last_modified_lag AS (
    SELECT *, 
    DATE_DIFF(last_modified_date, partition_date, DAY) last_modified_lag_days, 
    DATE_DIFF(creation_date, partition_date, DAY) creation_lag_days
    FROM all_partitions_with_partition_hour
  ),
  expected_date_sequence AS(
    SELECT 
      *
    FROM UNNEST(GENERATE_DATE_ARRAY(
      (SELECT DATE("2012-01-01")), 
      (SELECT max(partition_date) FROM all_partitions_with_last_modified_lag), 
      INTERVAL 1 day)) partition_date
    CROSS JOIN (SELECT DISTINCT table_catalog, table_schema, table_name, schema_table_name FROM all_partitions_with_partition_date)
  ),
  all_partitions_with_expected_dates AS (
    SELECT 
      * EXCEPT(partition_granularity),
      SUM(CASE WHEN total_rows IS NULL THEN 0 ELSE total_rows END) OVER (PARTITION BY partition_date, schema_table_name) total_rows_daily,
      DATE_TRUNC(partition_date, MONTH) partition_month,
      MAX(partition_granularity) OVER (PARTITION BY schema_table_name) partition_granularity
    FROM all_partitions_with_last_modified_lag
    FULL JOIN expected_date_sequence
    USING(partition_date, table_catalog, table_schema, table_name, schema_table_name)
  ),
  all_partitions_with_aggregates AS (
    SELECT 
      *,
      SUM(total_rows_daily) OVER (PARTITION BY partition_month, schema_table_name) total_rows_month,
      COUNTIF(partition_id IS NOT NULL) OVER (PARTITION BY partition_month, schema_table_name) partitions_per_month,
      COUNT(partition_date) OVER (PARTITION BY partition_month, schema_table_name) days_per_month
    FROM all_partitions_with_expected_dates
  ),  
  all_partitions_with_fixed_monthly AS (
    SELECT * EXCEPT(partition_granularity),
    IF (MAX(partitions_per_month) OVER (PARTITION BY schema_table_name) = 1, "monthly", partition_granularity) AS partition_granularity -- if there is at most one partition per month per table, then we can assume that it is actually monthly and not daily/hourly partitioning
    FROM all_partitions_with_aggregates
  ),
  all_partitions_with_interpolated_counts AS(
    SELECT
      *, 
      CASE 
        WHEN partition_id = "__UNPARTITIONED__" THEN total_rows_daily -- edge case voyages, which has monthly partitioning but also a dummy partition
        WHEN partition_granularity = "daily" THEN total_rows_daily
        WHEN partition_granularity = "monthly" THEN SAFE_DIVIDE(total_rows_month, days_per_month) 
        WHEN partition_granularity = "hourly" THEN total_rows_daily
        ELSE total_rows_daily
      END total_rows_daily_interpolated
      FROM all_partitions_with_fixed_monthly
  ),
  all_partitions_with_missing_count AS (
    SELECT 
      *,
      partition_id IS NULL 
      AND 
        (
          partition_granularity = 'daily' 
        OR 
          partition_date = partition_month
        ) missing_partition
    FROM all_partitions_with_interpolated_counts
  ),
  all_partitions_with_missing_aggregation AS (
    SELECT
      *,
      CAST(missing_partition AS INTEGER) missing_partition_int,
      SUM(CAST(missing_partition AS INTEGER)) OVER(PARTITION BY schema_table_name) table_total_missing_partitions
      FROM all_partitions_with_missing_count
  ),
  all_partitions_with_baseline_counts AS(
    SELECT 
      *,
      SUM(CASE WHEN schema_table_name = "pipe_production_v20201001.messages_segmented" THEN total_rows_daily ELSE 0 END) OVER (PARTITION BY partition_date) total_rows_daily_messages_baseline,
      SUM(CASE WHEN schema_table_name = "world-fishing-827.pipe_production_v20201001.research_segs" THEN total_rows_daily ELSE 0 END) OVER (PARTITION BY partition_date) total_rows_daily_segments_baseline,
      SUM(CASE WHEN schema_table_name = "pipe_production_v20201001.messages_segmented" THEN total_rows_daily ELSE 0 END) OVER (PARTITION BY partition_month) total_rows_month_messages_baseline,
      SUM(CASE WHEN schema_table_name = "world-fishing-827.pipe_production_v20201001.research_segs" THEN total_rows_daily ELSE 0 END) OVER (PARTITION BY partition_month) total_rows_month_segments_baseline
    FROM all_partitions_with_missing_aggregation
  ),
  partition_row_counts_with_baseline AS (
    SELECT 
      *,
      CASE 
        WHEN total_rows_daily_messages_baseline = 0 THEN 0 
        ELSE total_rows_daily_interpolated / total_rows_daily_messages_baseline
      END ratio_rows_daily_messages_baseline,
      CASE 
        WHEN total_rows_month_messages_baseline = 0 THEN 0 
        ELSE total_rows_month / total_rows_month_messages_baseline
      END ratio_rows_month_messages_baseline,
      CASE 
        WHEN total_rows_daily_segments_baseline = 0 THEN 0 
        ELSE total_rows_daily / total_rows_daily_segments_baseline
      END ratio_rows_daily_segments_baseline,
      CASE 
        WHEN total_rows_month_segments_baseline = 0 THEN 0 
        ELSE total_rows_month / total_rows_month_segments_baseline
      END ratio_rows_month_segments_baseline
    FROM all_partitions_with_baseline_counts
  ),
  partition_row_counts_normalised AS (
    SELECT 
      *,
      SAFE_DIVIDE(total_rows_daily_interpolated, MAX(total_rows_daily_interpolated) OVER (PARTITION BY schema_table_name)) normalised_total_rows_daily,
      SAFE_DIVIDE(total_rows_month, MAX(total_rows_month) OVER (PARTITION BY schema_table_name)) normalised_total_rows_month
    FROM partition_row_counts_with_baseline
  )

SELECT *, CURRENT_DATETIME() DASHBOARD_LAST_REFRESHED FROM partition_row_counts_normalised