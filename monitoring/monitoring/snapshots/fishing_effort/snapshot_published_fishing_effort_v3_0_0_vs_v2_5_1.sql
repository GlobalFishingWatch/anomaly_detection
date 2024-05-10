{% snapshot snapshot_published_fishing_effort_v3_0_0_vs_v2_5_1 %}

{{ config(
  target_schema='tech_great_expectations',
    unique_key='id',
    strategy='timestamp',
    updated_at='updated_at',
) }} 

WITH v3 AS (
  SELECT SUM(value) value, flag, geartype , date(timestamp) date
  FROM `skytruth-pelagos-production.ais_global_v3_fishing_effort_public.fishing_effort_public_stats_daily` 
  GROUP BY date, flag, geartype
),
v20231026 AS (
  SELECT SUM(value) value, flag, geartype , date(timestamp) date
  FROM `skytruth-pelagos-production.ais_global_v20231026_fishing_effort_public.ais_global_v20231026_fishing_effort_public_stats_daily` 
  GROUP BY date, flag, geartype
),
deltas AS (
  -- calculate deltas
  SELECT 
    COALESCE(v3.date, v20231026.date) date,
    COALESCE(v3.flag, v20231026.flag) flag,
    COALESCE(v3.geartype, v20231026.geartype) geartype,
    IFNULL(v3.value, 0) v3_value,
    IFNULL(v20231026.value, 0) v20231026_value,
    IFNULL(v3.value, 0) - IFNULL(v20231026.value, 0) delta,
    SAFE_DIVIDE(v3.value - v20231026.value, v20231026.value) delta_rel,
    CURRENT_TIMESTAMP() updated_at
  FROM v3
  FULL JOIN v20231026
  USING (date, flag, geartype)
),
deltas_with_id AS (
  SELECT *, ROW_NUMBER() OVER(ORDER BY date, flag, geartype) AS id
  FROM deltas
)

SELECT * FROM deltas_with_id

{% endsnapshot %}
