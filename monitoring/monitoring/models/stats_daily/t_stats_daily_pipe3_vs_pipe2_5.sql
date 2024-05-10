{{ config(
  materialized = 'table'
) }} 

WITH pipe3 AS (
    SELECT * FROM `world-fishing-827.pipe_ais_v3_published.stats_daily`
),
pipe2_5 AS (
    SELECT *, DATE(_PARTITIONTIME) AS DATE FROM `world-fishing-827.pipe_production_v20201001.research_stats`
)

SELECT
    COALESCE(pipe3.date, pipe2_5.date) AS date,
    pipe3.raw_positions - pipe2_5.raw_positions AS raw_positions_delta,
    pipe3.num_class_a_pos - pipe2_5.num_class_a_pos AS num_class_a_pos_delta,
    pipe3.num_class_b_pos - pipe2_5.num_class_b_pos AS num_class_b_pos_delta,
    pipe3.num_segs - pipe2_5.num_segs AS num_segs_delta,
    pipe3.num_ssvid - pipe2_5.num_ssvid AS num_ssvid_delta,
    pipe3.positions - pipe2_5.positions AS positions_delta,
    pipe3.terrestrial_positions - pipe2_5.terrestrial_positions AS terrestrial_positions_delta,
    pipe3.satellite_positions - pipe2_5.satellite_positions AS satellite_positions_delta,
    pipe3.satellite_positions_known_sat_location - pipe2_5.satellite_positions_known_sat_location AS satellite_positions_known_sat_location_delta,
    pipe3.num_positions_more_than_5000_km_from_sat - pipe2_5.num_positions_more_than_5000_km_from_sat AS num_positions_more_than_5000_km_from_sat_delta,
    pipe3.hours - pipe2_5.hours AS hours_delta,
    pipe3.fishing_hours - pipe2_5.fishing_hours AS fishing_hours_delta,
    pipe3.id_messages - pipe2_5.id_messages AS id_messages_delta,
    pipe3.id_a_messages - pipe2_5.id_a_messages AS id_a_messages_delta,
    pipe3.id_b_messages - pipe2_5.id_b_messages AS id_b_messages_delta,
    pipe3.overlap_hours - pipe2_5.overlap_hours AS overlap_hours_delta,
    pipe3.receivers - pipe2_5.receivers AS receivers_delta,
    pipe3.num_sattelites_off_by_60s_or_more - pipe2_5.num_sattelites_off_by_60s_or_more AS num_sattelites_off_by_60s_or_more_delta,


    SAFE_DIVIDE(pipe3.raw_positions - pipe2_5.raw_positions, pipe2_5.raw_positions) AS raw_positions_delta_rel,
    SAFE_DIVIDE(pipe3.num_class_a_pos - pipe2_5.num_class_a_pos, pipe2_5.num_class_a_pos) AS num_class_a_pos_delta_rel,
    SAFE_DIVIDE(pipe3.num_class_b_pos - pipe2_5.num_class_b_pos, pipe2_5.num_class_b_pos) AS num_class_b_pos_delta_rel,
    SAFE_DIVIDE(pipe3.num_segs - pipe2_5.num_segs, pipe2_5.num_segs) AS num_segs_delta_rel,
    SAFE_DIVIDE(pipe3.num_ssvid - pipe2_5.num_ssvid, pipe2_5.num_ssvid) AS num_ssvid_delta_rel,
    SAFE_DIVIDE(pipe3.positions - pipe2_5.positions, pipe2_5.positions) AS positions_delta_rel,
    SAFE_DIVIDE(pipe3.terrestrial_positions - pipe2_5.terrestrial_positions, pipe2_5.terrestrial_positions) AS terrestrial_positions_delta_rel,
    SAFE_DIVIDE(pipe3.satellite_positions - pipe2_5.satellite_positions, pipe2_5.satellite_positions) AS satellite_positions_delta_rel,
    SAFE_DIVIDE(pipe3.satellite_positions_known_sat_location - pipe2_5.satellite_positions_known_sat_location, pipe2_5.satellite_positions_known_sat_location) AS satellite_positions_known_sat_location_delta_rel,
    SAFE_DIVIDE(pipe3.num_positions_more_than_5000_km_from_sat - pipe2_5.num_positions_more_than_5000_km_from_sat, pipe2_5.num_positions_more_than_5000_km_from_sat) AS num_positions_more_than_5000_km_from_sat_delta_rel,
    SAFE_DIVIDE(pipe3.hours - pipe2_5.hours, pipe2_5.hours) AS hours_delta_rel,
    SAFE_DIVIDE(pipe3.fishing_hours - pipe2_5.fishing_hours, pipe2_5.fishing_hours) AS fishing_hours_delta_rel,
    SAFE_DIVIDE(pipe3.id_messages - pipe2_5.id_messages, pipe2_5.id_messages) AS id_messages_delta_rel,
    SAFE_DIVIDE(pipe3.id_a_messages - pipe2_5.id_a_messages, pipe2_5.id_a_messages) AS id_a_messages_delta_rel,
    SAFE_DIVIDE(pipe3.id_b_messages - pipe2_5.id_b_messages, pipe2_5.id_b_messages) AS id_b_messages_delta_rel,
    SAFE_DIVIDE(pipe3.overlap_hours - pipe2_5.overlap_hours, pipe2_5.overlap_hours) AS overlap_hours_delta_rel,
    SAFE_DIVIDE(pipe3.receivers - pipe2_5.receivers, pipe2_5.receivers) AS receivers_delta_rel,
    SAFE_DIVIDE(pipe3.num_sattelites_off_by_60s_or_more - pipe2_5.num_sattelites_off_by_60s_or_more, pipe2_5.num_sattelites_off_by_60s_or_more) AS num_sattelites_off_by_60s_or_more_delta_rel,



    pipe3.raw_positions AS raw_positions_pipe3,
    pipe3.num_class_a_pos AS num_class_a_pos_pipe3,
    pipe3.num_class_b_pos AS num_class_b_pos_pipe3,
    pipe3.num_segs AS num_segs_pipe3,
    pipe3.num_ssvid AS num_ssvid_pipe3,
    pipe3.positions AS positions_pipe3,
    pipe3.terrestrial_positions AS terrestrial_positions_pipe3,
    pipe3.satellite_positions AS satellite_positions_pipe3,
    pipe3.satellite_positions_known_sat_location AS satellite_positions_known_sat_location_pipe3,
    pipe3.num_positions_more_than_5000_km_from_sat AS num_positions_more_than_5000_km_from_sat_pipe3,
    pipe3.hours AS hours_pipe3,
    pipe3.fishing_hours AS fishing_hours_pipe3,
    pipe3.id_messages AS id_messages_pipe3,
    pipe3.id_a_messages AS id_a_messages_pipe3,
    pipe3.id_b_messages AS id_b_messages_pipe3,
    pipe3.overlap_hours AS overlap_hours_pipe3,
    pipe3.receivers AS receivers_pipe3,
    pipe3.num_sattelites_off_by_60s_or_more AS num_sattelites_off_by_60s_or_more_pipe3,
    
    
    
    pipe2_5.raw_positions AS raw_positions_pipe2_5,
    pipe2_5.num_class_a_pos AS num_class_a_pos_pipe2_5,
    pipe2_5.num_class_b_pos AS num_class_b_pos_pipe2_5,
    pipe2_5.num_segs AS num_segs_pipe2_5,
    pipe2_5.num_ssvid AS num_ssvid_pipe2_5,
    pipe2_5.positions AS positions_pipe2_5,
    pipe2_5.terrestrial_positions AS terrestrial_positions_pipe2_5,
    pipe2_5.satellite_positions AS satellite_positions_pipe2_5,
    pipe2_5.satellite_positions_known_sat_location AS satellite_positions_known_sat_location_pipe2_5,
    pipe2_5.num_positions_more_than_5000_km_from_sat AS num_positions_more_than_5000_km_from_sat_pipe2_5,
    pipe2_5.hours AS hours_pipe2_5,
    pipe2_5.fishing_hours AS fishing_hours_pipe2_5,
    pipe2_5.id_messages AS id_messages_pipe2_5,
    pipe2_5.id_a_messages AS id_a_messages_pipe2_5,
    pipe2_5.id_b_messages AS id_b_messages_pipe2_5,
    pipe2_5.overlap_hours AS overlap_hours_pipe2_5,
    pipe2_5.receivers AS receivers_pipe2_5,
    pipe2_5.num_sattelites_off_by_60s_or_more AS num_sattelites_off_by_60s_or_more_pipe2_5
FROM pipe3
FULL JOIN pipe2_5
USING(date)