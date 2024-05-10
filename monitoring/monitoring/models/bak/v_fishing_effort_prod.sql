{{ config(
  materialized = 'incremental',
  incremental_strategy = 'insert_overwrite',
  unique_key = 'date' ,
  partition_by = {'field': 'date', 'data_type': 'date'}
) }} 

WITH source_research_bad_mmsi AS (
  SELECT *
  FROM `world-fishing-827.gfw_research.bad_mmsi`
),
segs_activity_daily_pipe2_5_incl_archive AS (
  SELECT *, EXTRACT(year FROM _PARTITIONTIME) year, date(_PARTITIONTIME) date 
  FROM `pipe_production_v20201001.research_segs_daily`
  {% if is_incremental() %}
  WHERE date(_PARTITIONTIME) >= _dbt_max_partition
  {% endif %}
  UNION ALL 
  SELECT *, EXTRACT(year FROM _PARTITIONTIME) year, date(_PARTITIONTIME) date 
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
  SELECT SUM(fishing_hours) fishing_hours_pipe2_5, vessel_id, year, date
  FROM segs_activity_daily_pipe2_5_incl_archive sad
  INNER JOIN `pipe_production_v20201001.segment_info` si
  USING(seg_id)
  INNER JOIN segs_activity_pipe2_5
  USING(seg_id)
  GROUP BY year, date, vessel_id
),
segs_activity_pipe3 AS (
  SELECT seg_id FROM `pipe_ais_v3_alpha_published.segs_activity` sa
  WHERE good_seg
  AND NOT overlapping_and_short
),
segs_activity_daily_pipe3 AS (
  SELECT SUM(fishing_hours) fishing_hours_pipe3, vessel_id, EXTRACT(year FROM date) year, date
  FROM `pipe_ais_v3_alpha_published.segs_activity_daily` sad
  INNER JOIN `pipe_ais_v3_alpha_published.segment_info` si
  USING(seg_id)
  INNER JOIN segs_activity_pipe3
  USING(seg_id)
  WHERE date != '1979-01-01'
  {% if is_incremental() %}
  AND date >= _dbt_max_partition
  {% endif %}
  GROUP BY year, date, vessel_id
),
segs_activity_daily AS (
  SELECT 
  	sad_2_5.fishing_hours_pipe2_5, 
  	sad_3.fishing_hours_pipe3, 
  	COALESCE(sad_2_5.vessel_id, sad_3.vessel_id) vessel_id,
  	COALESCE(sad_2_5.year, sad_3.year) year,
  	COALESCE(sad_2_5.date, sad_3.date) date,
  FROM segs_activity_daily_pipe2_5 sad_2_5
  FULL JOIN segs_activity_daily_pipe3 sad_3
  USING(vessel_id, date)
),
av AS (
  SELECT * FROM `world-fishing-827.pipe_production_v20201001.all_vessels_byyear_v2_v20231201`
)

SELECT 
  CAST(SUM(fishing_hours_pipe2_5) AS INTEGER) sad_pipe2_5_fishing_hours, 
  CAST(SUM(fishing_hours_pipe3) AS INTEGER) sad_pipe3_fishing_hours, 
  CAST(SUM(fishing_hours_pipe3) - SUM(fishing_hours_pipe2_5) AS INTEGER) pipe_2_5_pipe_3_delta,
  ROUND((SUM(fishing_hours_pipe3) - SUM(fishing_hours_pipe2_5)) / SUM(fishing_hours_pipe2_5), 6) pipe_2_5_pipe_3_delta_rel,
  CAST(SUM(av.fishing_hours) AS INTEGER) av_fishing_hours, 
  date 
FROM av av
INNER JOIN segs_activity_daily sad
USING(vessel_id, year)
WHERE prod_shiptype = 'fishing'
AND NOT offsetting
AND (overlap_hours_multinames < 24 OR overlap_hours_multinames IS NULL)
AND (shipname_count <= 5 OR shipname_count IS NULL)
AND av.fishing_hours > 24
AND av.active_hours > 24*5
AND CAST(av.ssvid AS int64) NOT IN (SELECT ssvid FROM source_research_bad_mmsi, UNNEST(ssvid) as ssvid)
AND best_vessel_class != 'gear'
GROUP BY date