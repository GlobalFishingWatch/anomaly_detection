WITH
published_partitions AS (
  SELECT
    *
  FROM
    `world-fishing-827.pipe_ais_v3_alpha_published.INFORMATION_SCHEMA.PARTITIONS` ),
internal_partitions AS (
  SELECT
    *
  FROM
    `world-fishing-827.pipe_ais_v3_alpha_internal.INFORMATION_SCHEMA.PARTITIONS`
  WHERE
    table_name NOT LIKE '%_20%' ),
internal_shards AS (
  SELECT 
    project_id as table_catalog,
    dataset_id as table_schema,
    REGEXP_REPLACE(table_id, "(.*)?_20......", "\\1") as table_name,
    REGEXP_REPLACE(table_id, ".*?_(20......)", "\\1") as partition_id,
    row_count as total_rows,
    size_bytes AS total_logical_bytes,
    size_bytes AS total_billable_bytes,
    TIMESTAMP_MILLIS(last_modified_time) last_modified_time,
    '' AS storage_tier
  FROM `world-fishing-827.pipe_ais_v3_alpha_internal.__TABLES__`
  WHERE table_id  LIKE '%_20%'
    ),
all_partitions AS (
  SELECT * FROM published_partitions
  UNION ALL
  SELECT * FROM internal_partitions
  UNION ALL
  SELECT * FROM internal_shards
),
all_partitions_null_partition_cast AS (
  SELECT *, CASE 
    WHEN(partition_id = "__NULL__") THEN "201112" 
    WHEN(partition_id = "__UNPARTITIONED__") THEN "201112" 
    ELSE partition_id END as safe_partition_id
  FROM all_partitions
),
all_partitions_with_partition_date AS (
  SELECT *, 
  CASE
    WHEN CHAR_LENGTH(safe_partition_id) = 6 THEN PARSE_DATE('%Y%m', safe_partition_id)
    WHEN CHAR_LENGTH(safe_partition_id) = 8 THEN PARSE_DATE('%Y%m%d', safe_partition_id)
  END AS partition_date
  FROM all_partitions_null_partition_cast
),
all_partitions_with_partition_month AS (
  SELECT 
    *,
    DATE_TRUNC(partition_date, MONTH) partition_month
  FROM all_partitions_with_partition_date
),
expected_date_sequence AS(
  SELECT partition_date
  FROM UNNEST(GENERATE_DATE_ARRAY(
    (SELECT min(partition_date) FROM all_partitions_with_partition_month), 
    (SELECT max(partition_date) FROM all_partitions_with_partition_month), 
    INTERVAL 1 day)) partition_date
),
all_partitions_with_expected_dates AS (SELECT 
  *,
  CASE WHEN total_rows IS NULL THEN 0 ELSE total_rows END total_rows_safe,
  CONCAT(table_schema, ".", table_name) schema_table_name
FROM expected_date_sequence
LEFT JOIN 
all_partitions_with_partition_month
USING(partition_date)
),
all_partitions_with_published_messages_count AS(
  SELECT 
  *, 
  SUM(total_rows_safe) OVER (PARTITION BY partition_month, schema_table_name) total_rows_month,
  SUM(CASE WHEN schema_table_name = "pipe_ais_v3_alpha_internal.messages_segmented" THEN total_rows_safe ELSE 0 END) OVER (PARTITION BY partition_month) total_rows_month_baseline
FROM all_partitions_with_expected_dates
)
SELECT 
  *,
  CASE 
    WHEN total_rows_month_baseline = 0 THEN 0 
    ELSE total_rows_month / total_rows_month_baseline
  END ratio_total_rows_month_baseline
FROM all_partitions_with_published_messages_count