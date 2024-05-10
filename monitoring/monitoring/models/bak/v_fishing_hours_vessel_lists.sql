{{ config(materialized = 'view') }} 

with fishing_vessel_classes AS (
  SELECT *
  FROM unnest(
      [
      "dredge_fishing",
      "drifting_longlines",
      "driftnets",
      "other_fishing",
      "other_purse_seines",
      "other_seines",
      "pole_and_line",
      "pots_and_traps",
      "set_gillnets",
      "set_longlines",
      "squid_jigger",
      "trawlers",
      "trollers",
      "tuna_purse_seines",
      "fishing",
      "fixed_gear",
      "purse_seines",
      "seiners"]
    )
),
vi_table as (
  select *
  from `world-fishing-827.gfw_research.vi_ssvid_byyear`
),
fishing_sr_table as (
  select ssvid,
    year,
    safe_divide(
      sum(if(value = "Fishing", count, 0)),
      sum(
        if(
          value is not null
          and value != "Not available",
          count,
          0
        )
      )
    ) >.98
    and sum(
      if(
        value is not null
        and value != "Not available",
        count,
        0
      )
    ) > 50 on_fishing_list_sr_new
  from (
      select ssvid,
        year,
        v.value,
        v.count,
        on_fishing_list_sr
      from vi_table
        cross join unnest(ais_identity.shiptype) as v
    )
  group by ssvid,
    year
),
updated_best_table as (
  select ssvid,
    year,
    (
      CASE
        WHEN best.best_vessel_class IS NOT NULL
        AND best.best_vessel_class IN (
          SELECT *
          FROM fishing_vessel_classes
        )
        AND (
          # vessel is inferred, on regsitries, self reports
          (
            on_fishing_list_nn
            AND on_fishing_list_known IS NOT false
            AND on_fishing_list_sr_new
          )
          OR # vessel is inferred and on registries and scores over 0.85
          (
            on_fishing_list_nn
            AND on_fishing_list_known IS NOT false
            AND inferred.fishing_class_score > 0.85
          )
          OR # vessel is known fishing vessel from registry (and this is used for best vessel class)
          (
            on_fishing_list_known IS true
            AND (
              on_fishing_list_nn IS NULL
              OR on_fishing_list_nn
            )
          )
        ) # if any conditions are true, its on best fishing list
        THEN true
        ELSE false
      END
    ) AS on_fishing_list_best_new,
    on_fishing_list_sr_new,
    on_fishing_list_best,
    activity.fishing_hours
  from vi_table
    join fishing_sr_table using(ssvid, year)
)
select year,
  countif(on_fishing_list_best_new) on_fishing_list_best_fixed,
  countif(on_fishing_list_sr_new) on_fishing_list_sr_fixed,
  countif(on_fishing_list_best) on_fishing_list_best,
  countif(on_fishing_list_best_allyears) on_fishing_list_best_allyears,
  sum(if(on_fishing_list_best_new, fishing_hours, 0)) fishing_hours_best_fixed,
  sum(
    if(on_fishing_list_best_allyears, fishing_hours, 0)
  ) fishing_hours_best_allyears,
  sum(if(on_fishing_list_best, fishing_hours, 0)) fishing_hours_best,
  sum(if(on_fishing_list_sr_new, fishing_hours, 0)) fishing_hours_sr_fixed,
  from (
    select ssvid,
      year,
      on_fishing_list_best_new,
      on_fishing_list_sr_new,
      on_fishing_list_best,
      on_fishing_list_best_allyears,
      fishing_hours
    from updated_best_table
      join (
        select ssvid,
          on_fishing_list_best as on_fishing_list_best_allyears
        from `gfw_research.vi_ssvid_v20231201`
      ) using(ssvid)
  )
group by year
order by year