{{ config(materialized='view') }}

SELECT 
    * EXCEPT(job_stages, timeline, user_email), 
    user_email LIKE '%gserviceaccount%' AS service_account,
    TO_HEX(MD5(user_email)) user_email_hash
FROM {{ ref('t_world_fishing_827_queries') }}
LEFT JOIN {{ ref('t_team_emails') }} USING (user_email)