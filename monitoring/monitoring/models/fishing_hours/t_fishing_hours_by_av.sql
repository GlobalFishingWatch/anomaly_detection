{{ config(
  materialized = 'incremental',
  incremental_strategy = 'insert_overwrite',
  unique_key = 'date_week' ,
  partition_by = {'field': 'date_week', 'data_type': 'date'}
) }} 

WITH 
source_research_bad_mmsi AS (SELECT ssvid FROM world-fishing-827.tech_great_expectations.bad_mmsi),
segs_activity_daily AS (
  SELECT 
        sad_2_5.fishing_hours fishing_hours_pipe2_5, 
        sad_3.fishing_hours fishing_hours_pipe3, 
        COALESCE(sad_2_5.vessel_id, sad_3.vessel_id) vessel_id,
        COALESCE(sad_2_5.year, sad_3.year) year,
        COALESCE(sad_2_5.date_week, sad_3.date_week) date_week,
        COALESCE(sad_2_5.date, sad_3.date) date,
  FROM {{ ref('t_fishing_hours_pipe2_5') }} sad_2_5
  FULL JOIN {{ ref('t_fishing_hours_pipe3') }} sad_3
  USING(vessel_id, date)
  {% if is_incremental() %}
  WHERE COALESCE(sad_2_5.date_week, sad_3.date_week) >= _dbt_max_partition
  {% endif %}
),
av AS (
  SELECT *, PARSE_DATE("%Y%m%d", _TABLE_SUFFIX) all_vessels_v2_date FROM `world-fishing-827.pipe_production_v20201001.all_vessels_byyear_v2_v*`
)

SELECT 
  CAST(SUM(fishing_hours_pipe2_5) AS INTEGER) sad_pipe2_5_fishing_hours, 
  CAST(SUM(fishing_hours_pipe3) AS INTEGER) sad_pipe3_fishing_hours, 
  CAST(SUM(fishing_hours_pipe3) - SUM(fishing_hours_pipe2_5) AS INTEGER) pipe_2_5_pipe_3_delta,
  ROUND((SUM(fishing_hours_pipe3) - SUM(fishing_hours_pipe2_5)) / SUM(fishing_hours_pipe2_5), 6) pipe_2_5_pipe_3_delta_rel,
  CAST(SUM(av.fishing_hours) AS INTEGER) av_fishing_hours, 
  date_week,
  date,
  all_vessels_v2_date
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
GROUP BY date_week,date