{{ config(
  materialized = 'incremental',
  incremental_strategy = 'insert_overwrite',
  unique_key = 'date' ,
  partition_by = {'field': 'date', 'data_type': 'date'},
  cluster_by = ['user_email', 'query']
) }} 

SELECT
  creation_time,
  project_id,
  project_number,
  user_email,
  job_id,
  job_type,
  statement_type,
  priority,
  start_time,
  end_time,
  query,
  state,
  reservation_id,
  total_bytes_processed,
  total_slot_ms,
  error_result,
  cache_hit,
  destination_table,
  referenced_tables,
  labels,
  timeline,
  job_stages,
  total_bytes_billed,
  transaction_id,
  parent_job_id,
  session_info,
  dml_statistics,
  total_modified_partitions,
  bi_engine_statistics,
  transferred_bytes,
  materialized_view_statistics,
  DATE(creation_time) date, 
  CAST(total_bytes_billed / (1024 * 1024 * 1024) AS INTEGER) AS total_gb_billed
FROM
  `region-us`.INFORMATION_SCHEMA.JOBS
WHERE
  project_id = 'world-fishing-827'
-- AND DATE(creation_time) BETWEEN '2024-05-04' AND '2024-05-05'
{% if is_incremental() %}
-- incremental load gets data from maximum partition date PLUS 1 until today MINUS 1
AND DATE(creation_time) BETWEEN DATE_ADD(_dbt_max_partition, INTERVAL 1 DAY) AND DATE_SUB({{ dbt_date.today()}}, INTERVAL 1 DAY)
{% endif %}

