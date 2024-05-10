{% snapshot snapshot_published_fishing_events_v3_0_0_vs_v2_5_1 %}

{{ config(
  target_schema='tech_great_expectations',
    unique_key='id',
    strategy='timestamp',
    updated_at='updated_at',
) }} 

WITH
  v3 AS (
  SELECT
    COUNT(*) count,
    SUM(TIMESTAMP_DIFF(event_end, event_start, MINUTE)) event_duration,
    DATE(event_start) date
  FROM `skytruth-pelagos-production.ais_global_v3_public_common.events_fishing_public`
  GROUP BY date
),
  v20231026 AS (
  SELECT
    COUNT(*) count,
    SUM(TIMESTAMP_DIFF(event_end, event_start, MINUTE)) event_duration,
    DATE(event_start) date
  FROM `skytruth-pelagos-production.ais_global_v20231026_public_common.published_events_fishing`
  GROUP BY date
),
deltas AS (
  -- calculate deltas
  SELECT 
    COALESCE(v3.date, v20231026.date) date,
    IFNULL(v3.count, 0) v3_count,
    IFNULL(v20231026.count, 0) v20231026_count,
    IFNULL(v3.count, 0) - IFNULL(v20231026.count, 0) delta_count,
    SAFE_DIVIDE(v3.count - v20231026.count, v20231026.count) delta_count_rel,
    IFNULL(v3.event_duration, 0) v3_event_duration,
    IFNULL(v20231026.event_duration, 0) v20231026_event_duration,
    IFNULL(v3.event_duration, 0) - IFNULL(v20231026.event_duration, 0) delta_event_duration,
    SAFE_DIVIDE(v3.event_duration - v20231026.event_duration, v20231026.event_duration) delta_event_duration_rel,
    CURRENT_TIMESTAMP() updated_at
  FROM v3
  FULL JOIN v20231026
  USING (date)
),
deltas_with_id AS (
  SELECT *, ROW_NUMBER() OVER(ORDER BY date) AS id
  FROM deltas
)

SELECT * FROM deltas_with_id

{% endsnapshot %}
