{{ config(
  materialized = 'incremental',
  incremental_strategy = 'insert_overwrite',
  unique_key = 'date_week' ,
  partition_by = {'field': 'date_week', 'data_type': 'date'}
) }} 

WITH 
segs_activity_daily_pipe2_5_incl_archive AS (
  SELECT *, EXTRACT(year FROM _PARTITIONTIME) year, date(_PARTITIONTIME) date , DATE(DATETIME_TRUNC(_PARTITIONTIME, WEEK)) date_week
  FROM `pipe_production_v20201001.research_segs_daily`
  {% if is_incremental() %}
  WHERE date(_PARTITIONTIME) >= _dbt_max_partition
  {% endif %}
  UNION ALL 
  SELECT *, EXTRACT(year FROM _PARTITIONTIME) year, date(_PARTITIONTIME) date , DATE(DATETIME_TRUNC(_PARTITIONTIME, WEEK)) date_week
  FROM `pipe_production_v20201001.archive_research_segs_daily`
  {% if is_incremental() %}
  WHERE date(_PARTITIONTIME) >= _dbt_max_partition
  {% endif %}
),
segs_activity_pipe2_5 AS (
  SELECT seg_id FROM `pipe_production_v20201001.research_segs` sa
  WHERE good_seg
  AND NOT overlapping_and_short
),
segs_activity_daily_pipe2_5 AS (
  SELECT SUM(fishing_hours) fishing_hours, vessel_id, year, date, date_week
  FROM segs_activity_daily_pipe2_5_incl_archive sad
  INNER JOIN `pipe_production_v20201001.segment_info` si
  USING(seg_id)
  INNER JOIN segs_activity_pipe2_5
  USING(seg_id)
  GROUP BY year, date_week, date, vessel_id
)
SELECT fishing_hours, vessel_id, year, date_week, date FROM segs_activity_daily_pipe2_5