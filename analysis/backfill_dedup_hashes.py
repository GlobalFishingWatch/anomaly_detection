"""
One-off script to pre-populate the alerting deduplication index with
new-style (fuzzy) hashes for anomalies already visible in the deltas
table. Prevents a re-alert spike during the transition from the old
value-based hash to the new classification-based hash.

Safe to re-run: uses `NOT IN (SELECT event_hash FROM ...)` so already-present
hashes are skipped.
"""

import datetime
import hashlib

from google.cloud import bigquery

ENVIRONMENT = "dev"
DEDUP_TABLE = (
    f"world-fishing-827.tech_anomaly_detection."
    f"t_qa_gfw_anomaly_detection_alerting_{ENVIRONMENT}_deduplication-index"
)
DELTAS_TABLE = f"world-fishing-827.tech_anomaly_detection.t_{ENVIRONMENT}_deltas"

client = bigquery.Client(project="world-fishing-827")

deltas_query = f"""
SELECT
    config_name,
    dimension_split_value,
    forecast_method,
    timestamp,
    anomaly_type_lower_higher
FROM `{DELTAS_TABLE}`
WHERE anomaly_type != 'normal'
  AND timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30*24 HOUR)
"""

# The gfw_api_delays config was changed to monitor vs_expected lag. The next
# dataloader run will populate deltas with new rows that aren't here yet --
# predict them by querying the source view directly so the dedup index
# covers them before they're alerted on.
gfw_api_delays_forecast_query = """
SELECT
    'gfw_api_delays' AS config_name,
    dataset AS dimension_split_value,
    'constant_value' AS forecast_method,
    TIMESTAMP_TRUNC(timestamp, DAY) AS timestamp,
    'critical_higher' AS anomaly_type_lower_higher
FROM `world-fishing-827.tech_dq_monitoring.v_scraped_api_values`
WHERE date_interval = 'DAY'
  AND environment = 'prod'
  AND timestamp_delay_now_hypothetical_vs_expected_delay_hour > 1
  AND date >= first_valid_from_date
GROUP BY dataset, timestamp
"""

rows = list(client.query(deltas_query).result())
print(f"Found {len(rows)} anomalous rows in deltas")

forecast_rows = list(client.query(gfw_api_delays_forecast_query).result())
print(f"Predicted {len(forecast_rows)} gfw_api_delays rows from view")
rows = rows + forecast_rows

now_ts = datetime.datetime.now(datetime.timezone.utc)
new_rows = []
for row in rows:
    columns_used = [
        row["config_name"],
        row["dimension_split_value"],
        row["forecast_method"],
        row["timestamp"],
        row["anomaly_type_lower_higher"],
    ]
    event_hash = hashlib.sha256(str(columns_used).encode()).hexdigest()
    new_rows.append({
        "event_hash": event_hash,
        "processed_at": now_ts.isoformat(),
        "rendered_message": (
            f"[backfill] {row['config_name']} / "
            f"{row['dimension_split_value']} / "
            f"{row['forecast_method']} / "
            f"{row['timestamp'].isoformat()} / "
            f"{row['anomaly_type_lower_higher']}"
        ),
    })

existing_query = f"""
SELECT event_hash FROM `{DEDUP_TABLE}`
WHERE processed_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 60 DAY)
"""
existing_hashes = {row["event_hash"] for row in client.query(existing_query).result()}
print(f"Existing dedup hashes in last 60d: {len(existing_hashes)}")

to_insert = [r for r in new_rows if r["event_hash"] not in existing_hashes]
print(f"Rows to insert (not yet in dedup): {len(to_insert)}")

if to_insert:
    errors = client.insert_rows_json(DEDUP_TABLE, to_insert)
    if errors:
        raise RuntimeError(f"Insert errors: {errors}")
    print(f"Inserted {len(to_insert)} rows into dedup index")
else:
    print("Nothing to insert")
