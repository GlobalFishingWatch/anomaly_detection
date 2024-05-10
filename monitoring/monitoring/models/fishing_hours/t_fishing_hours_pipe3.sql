{{ config(
  materialized = 'incremental',
  incremental_strategy = 'insert_overwrite',
  unique_key = 'date_week' ,
  partition_by = {'field': 'date_week', 'data_type': 'date'}
) }} 

WITH 
segs_activity_pipe3 AS (
  SELECT seg_id FROM `pipe_ais_v3_alpha_published.segs_activity` sa
  WHERE good_seg
  AND NOT overlapping_and_short
),
segs_activity_daily_pipe3 AS (
  SELECT SUM(fishing_hours) fishing_hours, vessel_id, EXTRACT(year FROM date) year, date , DATE(DATE_TRUNC(date, WEEK)) date_week
  FROM `pipe_ais_v3_alpha_published.segs_activity_daily` sad
  INNER JOIN `pipe_ais_v3_alpha_published.segment_info` si
  USING(seg_id)
  INNER JOIN segs_activity_pipe3
  USING(seg_id)
  WHERE date != '1979-01-01'
  {% if is_incremental() %}
  AND date >= _dbt_max_partition
  {% endif %}
  
  GROUP BY year, date_week, date, vessel_id
)
SELECT fishing_hours, vessel_id, year, date_week, date FROM segs_activity_daily_pipe3