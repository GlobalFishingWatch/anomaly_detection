{{ config(
  materialized = 'incremental',
  incremental_strategy = 'insert_overwrite',
  unique_key = 'date' ,
  partition_by = {'field': 'date', 'data_type': 'date'},
  cluster_by = ['parser', 'source', 'error', 'tagblock_station']
) }} 


SELECT
  COUNT(*) count,
  DATE(tagblock_timestamp) date,
  source,
  error,
  tagblock_timestamp,
  tagblock_channel,
  tagblock_groupsize,
  tagblock_id,
  tagblock_q,
  tagblock_sentence,
  tagblock_station,
  parser,
  CASE 
    WHEN error LIKE '%No valid AIVDM found in%' 
      THEN 'No valid AIVDM found in '
    WHEN error LIKE '%AISTOOLS ERR: None  LIBAIS ERR: Ais6: DAC:FI not known.%' 
      THEN 'AISTOOLS ERR: None  LIBAIS ERR: Ais6: DAC:FI not known.'
    WHEN error LIKE '%AISTOOLS ERR: Not enough bits to decode.  Need at least%' 
      THEN 'AISTOOLS ERR: Not enough bits to decode.  Need at least'
  ELSE error
  END AS classified_error,
  tagblock_groupsize - tagblock_sentence AS tagblock_sentence_reversed
FROM `world-fishing-827.pipe_ais_sources_v20201001.pipe-nmea-parsed` 
WHERE 1=1
AND error IS NOT NULL
{% if is_incremental() %}
AND DATE(tagblock_timestamp) >= _dbt_max_partition
{% endif %}
GROUP BY 
  date,
  source,
  error,
  tagblock_timestamp,
  tagblock_channel,
  tagblock_groupsize,
  tagblock_id,
  tagblock_q,
  tagblock_sentence,
  tagblock_station,
  parser,
  classified_error