
{{ config(materialized='table') }}

WITH
  unioned_dataset_partitions AS (
    SELECT * FROM `world-fishing-827.pipe_ais_v3_alpha_published.INFORMATION_SCHEMA.PARTITIONS`
    UNION ALL
    SELECT * FROM `world-fishing-827.pipe_ais_v3_alpha_internal.INFORMATION_SCHEMA.PARTITIONS`
    UNION ALL
    SELECT * FROM `world-fishing-827.pipe_production_v20201001.INFORMATION_SCHEMA.PARTITIONS`
  ),
  unioned_dataset_shards AS (
    SELECT * FROM `world-fishing-827.pipe_ais_v3_alpha_published.__TABLES__`
    UNION ALL
    SELECT * FROM `world-fishing-827.pipe_ais_v3_alpha_internal.__TABLES__`
    UNION ALL
    SELECT * FROM `world-fishing-827.pipe_production_v20201001.__TABLES__`
  ),
  partitioned_tables AS (
    SELECT *
    FROM unioned_dataset_partitions
    WHERE table_name NOT LIKE '%_20%' ),
  sharded_tables AS (
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
    FROM unioned_dataset_shards
    WHERE table_id  LIKE '%\\_20______' -- matches e.g. _20230101 but excludes _2012 and potential _2013 tables
      ),
  all_partitions AS (
    SELECT * FROM partitioned_tables
    UNION ALL
    SELECT * FROM sharded_tables
  )

SELECT * FROM all_partitions