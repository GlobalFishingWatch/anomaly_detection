{{ config(
    materialized = 'view'
) }} 

SELECT *
FROM {{ ref('snapshot_published_fishing_events_v3_0_0_vs_v2_5_1') }}
WHERE dbt_valid_to IS NULL