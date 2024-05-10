{{ config(
  materialized = 'table'
) }} 

WITH floats AS (
    SELECT
        date,

        CAST(raw_positions_pipe3 AS FLOAT64) AS raw_positions_pipe3,
        CAST(num_class_a_pos_pipe3 AS FLOAT64) AS num_class_a_pos_pipe3,
        CAST(num_class_b_pos_pipe3 AS FLOAT64) AS num_class_b_pos_pipe3,
        CAST(num_segs_pipe3 AS FLOAT64) AS num_segs_pipe3,
        CAST(num_ssvid_pipe3 AS FLOAT64) AS num_ssvid_pipe3,
        CAST(positions_pipe3 AS FLOAT64) AS positions_pipe3,
        CAST(terrestrial_positions_pipe3 AS FLOAT64) AS terrestrial_positions_pipe3,
        CAST(satellite_positions_pipe3 AS FLOAT64) AS satellite_positions_pipe3,
        CAST(satellite_positions_known_sat_location_pipe3 AS FLOAT64) AS satellite_positions_known_sat_location_pipe3,
        CAST(num_positions_more_than_5000_km_from_sat_pipe3 AS FLOAT64) AS num_positions_more_than_5000_km_from_sat_pipe3,
        CAST(hours_pipe3 AS FLOAT64) AS hours_pipe3,
        CAST(fishing_hours_pipe3 AS FLOAT64) AS fishing_hours_pipe3,
        CAST(id_messages_pipe3 AS FLOAT64) AS id_messages_pipe3,
        CAST(id_a_messages_pipe3 AS FLOAT64) AS id_a_messages_pipe3,
        CAST(id_b_messages_pipe3 AS FLOAT64) AS id_b_messages_pipe3,
        CAST(overlap_hours_pipe3 AS FLOAT64) AS overlap_hours_pipe3,
        CAST(receivers_pipe3 AS FLOAT64) AS receivers_pipe3,
        CAST(num_sattelites_off_by_60s_or_more_pipe3 AS FLOAT64) AS num_sattelites_off_by_60s_or_more_pipe3,


        CAST(raw_positions_pipe2_5 AS FLOAT64) AS raw_positions_pipe2_5,
        CAST(num_class_a_pos_pipe2_5 AS FLOAT64) AS num_class_a_pos_pipe2_5,
        CAST(num_class_b_pos_pipe2_5 AS FLOAT64) AS num_class_b_pos_pipe2_5,
        CAST(num_segs_pipe2_5 AS FLOAT64) AS num_segs_pipe2_5,
        CAST(num_ssvid_pipe2_5 AS FLOAT64) AS num_ssvid_pipe2_5,
        CAST(positions_pipe2_5 AS FLOAT64) AS positions_pipe2_5,
        CAST(terrestrial_positions_pipe2_5 AS FLOAT64) AS terrestrial_positions_pipe2_5,
        CAST(satellite_positions_pipe2_5 AS FLOAT64) AS satellite_positions_pipe2_5,
        CAST(satellite_positions_known_sat_location_pipe2_5 AS FLOAT64) AS satellite_positions_known_sat_location_pipe2_5,
        CAST(num_positions_more_than_5000_km_from_sat_pipe2_5 AS FLOAT64) AS num_positions_more_than_5000_km_from_sat_pipe2_5,
        CAST(hours_pipe2_5 AS FLOAT64) AS hours_pipe2_5,
        CAST(fishing_hours_pipe2_5 AS FLOAT64) AS fishing_hours_pipe2_5,
        CAST(id_messages_pipe2_5 AS FLOAT64) AS id_messages_pipe2_5,
        CAST(id_a_messages_pipe2_5 AS FLOAT64) AS id_a_messages_pipe2_5,
        CAST(id_b_messages_pipe2_5 AS FLOAT64) AS id_b_messages_pipe2_5,
        CAST(overlap_hours_pipe2_5 AS FLOAT64) AS overlap_hours_pipe2_5,
        CAST(receivers_pipe2_5 AS FLOAT64) AS receivers_pipe2_5,
        CAST(num_sattelites_off_by_60s_or_more_pipe2_5 AS FLOAT64) AS num_sattelites_off_by_60s_or_more_pipe2_5,


        CAST(raw_positions_delta AS FLOAT64) AS raw_positions_delta,
        CAST(num_class_a_pos_delta AS FLOAT64) AS num_class_a_pos_delta,
        CAST(num_class_b_pos_delta AS FLOAT64) AS num_class_b_pos_delta,
        CAST(num_segs_delta AS FLOAT64) AS num_segs_delta,
        CAST(num_ssvid_delta AS FLOAT64) AS num_ssvid_delta,
        CAST(positions_delta AS FLOAT64) AS positions_delta,
        CAST(terrestrial_positions_delta AS FLOAT64) AS terrestrial_positions_delta,
        CAST(satellite_positions_delta AS FLOAT64) AS satellite_positions_delta,
        CAST(satellite_positions_known_sat_location_delta AS FLOAT64) AS satellite_positions_known_sat_location_delta,
        CAST(num_positions_more_than_5000_km_from_sat_delta AS FLOAT64) AS num_positions_more_than_5000_km_from_sat_delta,
        CAST(hours_delta AS FLOAT64) AS hours_delta,
        CAST(fishing_hours_delta AS FLOAT64) AS fishing_hours_delta,
        CAST(id_messages_delta AS FLOAT64) AS id_messages_delta,
        CAST(id_a_messages_delta AS FLOAT64) AS id_a_messages_delta,
        CAST(id_b_messages_delta AS FLOAT64) AS id_b_messages_delta,
        CAST(overlap_hours_delta AS FLOAT64) AS overlap_hours_delta,
        CAST(receivers_delta AS FLOAT64) AS receivers_delta,
        CAST(num_sattelites_off_by_60s_or_more_delta AS FLOAT64) AS num_sattelites_off_by_60s_or_more_delta,


        CAST(raw_positions_delta_rel AS FLOAT64) AS raw_positions_delta_rel,
        CAST(num_class_a_pos_delta_rel AS FLOAT64) AS num_class_a_pos_delta_rel,
        CAST(num_class_b_pos_delta_rel AS FLOAT64) AS num_class_b_pos_delta_rel,
        CAST(num_segs_delta_rel AS FLOAT64) AS num_segs_delta_rel,
        CAST(num_ssvid_delta_rel AS FLOAT64) AS num_ssvid_delta_rel,
        CAST(positions_delta_rel AS FLOAT64) AS positions_delta_rel,
        CAST(terrestrial_positions_delta_rel AS FLOAT64) AS terrestrial_positions_delta_rel,
        CAST(satellite_positions_delta_rel AS FLOAT64) AS satellite_positions_delta_rel,
        CAST(satellite_positions_known_sat_location_delta_rel AS FLOAT64) AS satellite_positions_known_sat_location_delta_rel,
        CAST(num_positions_more_than_5000_km_from_sat_delta_rel AS FLOAT64) AS num_positions_more_than_5000_km_from_sat_delta_rel,
        CAST(hours_delta_rel AS FLOAT64) AS hours_delta_rel,
        CAST(fishing_hours_delta_rel AS FLOAT64) AS fishing_hours_delta_rel,
        CAST(id_messages_delta_rel AS FLOAT64) AS id_messages_delta_rel,
        CAST(id_a_messages_delta_rel AS FLOAT64) AS id_a_messages_delta_rel,
        CAST(id_b_messages_delta_rel AS FLOAT64) AS id_b_messages_delta_rel,
        CAST(overlap_hours_delta_rel AS FLOAT64) AS overlap_hours_delta_rel,
        CAST(receivers_delta_rel AS FLOAT64) AS receivers_delta_rel,
        CAST(num_sattelites_off_by_60s_or_more_delta_rel AS FLOAT64) AS num_sattelites_off_by_60s_or_more_delta_rel,
    FROM {{ ref('t_stats_daily_pipe3_vs_pipe2_5') }}
),
unpivoted_measures AS (
    SELECT * FROM floats
        UNPIVOT(
            (pipe3_value, pipe2_5_value, delta_value, delta_rel_value) FOR measure IN (
                (
                    raw_positions_pipe3, raw_positions_pipe2_5, raw_positions_delta, raw_positions_delta_rel  
                ) AS 'raw_positions',
                (
                    num_class_a_pos_pipe3, num_class_a_pos_pipe2_5, num_class_a_pos_delta, num_class_a_pos_delta_rel
                ) AS 'num_class_a_pos',
                (
                    num_class_b_pos_pipe3, num_class_b_pos_pipe2_5, num_class_b_pos_delta, num_class_b_pos_delta_rel
                ) AS 'num_class_b_pos',
                (
                    num_segs_pipe3, num_segs_pipe2_5, num_segs_delta, num_segs_delta_rel
                ) AS 'num_segs',
                (
                    num_ssvid_pipe3, num_ssvid_pipe2_5, num_ssvid_delta, num_ssvid_delta_rel
                ) AS 'num_ssvid',
                (
                    positions_pipe3, positions_pipe2_5, positions_delta, positions_delta_rel
                ) AS 'positions',
                (
                    terrestrial_positions_pipe3, terrestrial_positions_pipe2_5, terrestrial_positions_delta, terrestrial_positions_delta_rel
                ) AS 'terrestrial_positions',
                (
                    satellite_positions_pipe3, satellite_positions_pipe2_5, satellite_positions_delta, satellite_positions_delta_rel
                ) AS 'satellite_positions',
                (
                    satellite_positions_known_sat_location_pipe3, satellite_positions_known_sat_location_pipe2_5, satellite_positions_known_sat_location_delta, satellite_positions_known_sat_location_delta_rel
                ) AS 'satellite_positions_known_sat_location',
                (
                    num_positions_more_than_5000_km_from_sat_pipe3, num_positions_more_than_5000_km_from_sat_pipe2_5, num_positions_more_than_5000_km_from_sat_delta, num_positions_more_than_5000_km_from_sat_delta_rel
                ) AS 'num_positions_more_than_5000_km_from_sat',
                (
                    hours_pipe3, hours_pipe2_5, hours_delta, hours_delta_rel
                ) AS 'hours',
                (
                    fishing_hours_pipe3, fishing_hours_pipe2_5, fishing_hours_delta, fishing_hours_delta_rel
                ) AS 'fishing_hours',
                (
                    id_messages_pipe3, id_messages_pipe2_5, id_messages_delta, id_messages_delta_rel
                ) AS 'id_messages',
                (
                    id_a_messages_pipe3, id_a_messages_pipe2_5, id_a_messages_delta, id_a_messages_delta_rel
                ) AS 'id_a_messages',
                (
                    id_b_messages_pipe3, id_b_messages_pipe2_5, id_b_messages_delta, id_b_messages_delta_rel
                ) AS 'id_b_messages',
                (
                    overlap_hours_pipe3, overlap_hours_pipe2_5, overlap_hours_delta, overlap_hours_delta_rel
                ) AS 'overlap_hours',
                (
                    receivers_pipe3, receivers_pipe2_5, receivers_delta, receivers_delta_rel
                ) AS 'receivers',
                (
                    num_sattelites_off_by_60s_or_more_pipe3, num_sattelites_off_by_60s_or_more_pipe2_5, num_sattelites_off_by_60s_or_more_delta, num_sattelites_off_by_60s_or_more_delta_rel
                ) AS 'num_sattelites_off_by_60s_or_more'
            )
        )
)
SELECT * FROM unpivoted_measures
UNPIVOT(
    (value) FOR metric IN (
        delta_value, delta_rel_value, pipe3_value, pipe2_5_value
    )
)