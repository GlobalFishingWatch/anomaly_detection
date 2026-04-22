"""BigQuery queries and writes for the threaded-alerting flow.

All Slack-writing callers should go through these helpers so the SQL is in
one place. Writes use DML `INSERT INTO ... VALUES (...)` executed as query
jobs rather than streaming inserts -- DML lands rows in managed storage
immediately, avoiding the 30-90 minute streaming buffer window during
which UPDATE/DELETE on newly-inserted rows is rejected.

Table names supplied by the caller (CLI args) are canonicalized through
`canonical_table_id()` before being interpolated into SQL to prevent
identifier injection.
"""

from __future__ import annotations

import datetime
import uuid

from google.cloud import bigquery


DELTAS_TABLE_TEMPLATE = "world-fishing-827.tech_anomaly_detection.t_{env}_deltas"
CHANNEL_MAPPING_TABLE = (
    "world-fishing-827.tech_anomaly_detection.slack_channels_environments_config_mapping"
)
ALLOWED_ENVIRONMENTS = frozenset({"dev", "staging", "main", "prod"})


def canonical_table_id(table_id: str) -> str:
    """Parse `project.dataset.table` and reconstruct the canonical id.

    Rejects anything that doesn't parse as a valid BigQuery table triple --
    in particular anything containing backticks, whitespace, or SQL
    metacharacters. Safe to interpolate into a SQL statement inside
    backticks after this.
    """
    # Sanity-check before handing to the SDK: reject unexpected characters
    # so a single-dotted "dataset.table" can't accidentally pick up the
    # client's default project.
    if not all(c.isalnum() or c in "._-" for c in table_id):
        raise ValueError(f"Invalid table id: {table_id!r}")
    ref = bigquery.TableReference.from_string(table_id)
    return f"{ref.project}.{ref.dataset_id}.{ref.table_id}"


def canonical_environment(env: str) -> str:
    """Validate the environment name before interpolating into a table
    template."""
    if env not in ALLOWED_ENVIRONMENTS:
        raise ValueError(
            f"Invalid environment: {env!r} (allowed: {sorted(ALLOWED_ENVIRONMENTS)})"
        )
    return env


# --- channel routing ---------------------------------------------------

def get_channel_config(client: bigquery.Client, config_name: str, environment: str) -> dict:
    """Look up (slack_channel_id, thread_timeout_hours) for a (config, env)
    using the three-tier fallback: exact match > env-only match > first row.
    Raises if nothing matches at all."""
    query = f"""
    SELECT
      CASE
        WHEN config_name = @config_name AND environment = @environment THEN 1
        WHEN config_name IS NULL AND environment = @environment THEN 2
        ELSE 3
      END AS priority,
      slack_channel_id,
      slack_channel_name,
      thread_timeout_hours
    FROM `{CHANNEL_MAPPING_TABLE}`
    ORDER BY priority
    LIMIT 1
    """
    job = client.query(query, job_config=bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("config_name", "STRING", config_name),
            bigquery.ScalarQueryParameter("environment", "STRING", environment),
        ],
    ))
    rows = list(job.result())
    if not rows:
        raise ValueError(f"No Slack channel mapping found for {config_name}/{environment}")
    r = rows[0]
    return {
        "slack_channel_id": r["slack_channel_id"],
        "slack_channel_name": r["slack_channel_name"],
        "thread_timeout_hours": r.get("thread_timeout_hours"),
    }


# --- deltas query ------------------------------------------------------

def query_deltas_with_open_replies(
    client: bigquery.Client, environment: str, replies_table: str,
) -> list[dict]:
    """Return the latest deltas row per (config, dim, method) for any key
    that either was anomalous in the last 30 days or has an open reply.

    The state machine treats the latest row per key as the current state,
    so we must include the most recent row -- even if it's 'normal' --
    for every key of interest. Otherwise a key that was critical weeks
    ago but has since returned to normal would still look critical from
    the state machine's perspective.
    """
    deltas = DELTAS_TABLE_TEMPLATE.format(env=environment)
    query = f"""
    WITH keys_of_interest AS (
      SELECT DISTINCT config_name,
                      IFNULL(dimension_split_value, '') AS dimension_split_value,
                      forecast_method
      FROM `{deltas}`
      WHERE anomaly_type != 'normal'
        AND timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30*24 HOUR)
      UNION DISTINCT
      SELECT DISTINCT config_name,
                      IFNULL(dimension_split_value, '') AS dimension_split_value,
                      forecast_method
      FROM `{replies_table}`
      WHERE status = 'open'
    )
    SELECT d.*
    FROM `{deltas}` d
    JOIN keys_of_interest k
      ON d.config_name = k.config_name
     AND IFNULL(d.dimension_split_value, '') = k.dimension_split_value
     AND d.forecast_method = k.forecast_method
    WHERE d.timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30*24 HOUR)
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY d.config_name, IFNULL(d.dimension_split_value, ''), d.forecast_method
      ORDER BY d.timestamp DESC
    ) = 1
    """
    rows = []
    for r in client.query(query, job_config=bigquery.QueryJobConfig(use_query_cache=False)).result():
        rows.append(dict(r.items()))
    return rows


# --- incidents ---------------------------------------------------------

def find_open_incident(client: bigquery.Client, incidents_table: str,
                       config_name: str) -> dict | None:
    query = f"""
    SELECT *
    FROM `{incidents_table}`
    WHERE config_name = @config_name AND status = 'open'
    ORDER BY opened_at DESC
    LIMIT 1
    """
    job = client.query(query, job_config=bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter(
            "config_name", "STRING", config_name)],
    ))
    rows = list(job.result())
    if not rows:
        return None
    return dict(rows[0].items())


def list_configs_with_activity(
    client: bigquery.Client, environment: str, incidents_table: str,
) -> list[str]:
    """Return the union of configs with anomalies in the last 30d and
    configs with open incidents. One row per config name."""
    deltas = DELTAS_TABLE_TEMPLATE.format(env=environment)
    query = f"""
    SELECT DISTINCT config_name FROM `{deltas}`
    WHERE anomaly_type != 'normal'
      AND timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30*24 HOUR)
    UNION DISTINCT
    SELECT DISTINCT config_name FROM `{incidents_table}`
    WHERE status = 'open'
    """
    return [r["config_name"] for r in client.query(query).result()]


def insert_incident(client: bigquery.Client, incidents_table: str, *,
                    config_name: str, slack_channel_id: str, slack_ts: str,
                    now: datetime.datetime, summary_counts_json: str,
                    client_msg_id: str) -> None:
    # DML INSERT writes to managed storage immediately; insert_rows_json
    # would put the row in the streaming buffer and block subsequent
    # UPDATE/DELETE on the same row for 30-90 minutes.
    query = f"""
    INSERT INTO `{incidents_table}` (
      config_name, slack_channel_id, slack_ts, opened_at, last_activity_at,
      closed_at, status, client_msg_id, summary_counts_json
    )
    VALUES (
      @config_name, @slack_channel_id, @slack_ts, @now, @now,
      NULL, 'open', @client_msg_id, @summary_counts_json
    )
    """
    params = [
        bigquery.ScalarQueryParameter("config_name", "STRING", config_name),
        bigquery.ScalarQueryParameter("slack_channel_id", "STRING", slack_channel_id),
        bigquery.ScalarQueryParameter("slack_ts", "STRING", slack_ts),
        bigquery.ScalarQueryParameter("now", "TIMESTAMP", now),
        bigquery.ScalarQueryParameter("client_msg_id", "STRING", client_msg_id),
        bigquery.ScalarQueryParameter("summary_counts_json", "STRING", summary_counts_json),
    ]
    client.query(query, job_config=bigquery.QueryJobConfig(
        query_parameters=params)).result()


def update_incident(client: bigquery.Client, incidents_table: str, *,
                    slack_ts: str, now: datetime.datetime,
                    summary_counts_json: str | None = None,
                    status: str | None = None,
                    closed_at: datetime.datetime | None = None) -> None:
    sets = ["last_activity_at = @now"]
    params = [
        bigquery.ScalarQueryParameter("slack_ts", "STRING", slack_ts),
        bigquery.ScalarQueryParameter("now", "TIMESTAMP", now),
    ]
    if summary_counts_json is not None:
        sets.append("summary_counts_json = @summary")
        params.append(bigquery.ScalarQueryParameter(
            "summary", "STRING", summary_counts_json))
    if status is not None:
        sets.append("status = @status")
        params.append(bigquery.ScalarQueryParameter("status", "STRING", status))
    if closed_at is not None:
        sets.append("closed_at = @closed_at")
        params.append(bigquery.ScalarQueryParameter("closed_at", "TIMESTAMP", closed_at))
    query = (f"UPDATE `{incidents_table}` SET " + ", ".join(sets) +
             " WHERE slack_ts = @slack_ts")
    client.query(query, job_config=bigquery.QueryJobConfig(
        query_parameters=params)).result()


# --- replies ----------------------------------------------------------

def find_open_replies(client: bigquery.Client, replies_table: str,
                      config_name: str) -> list[dict]:
    query = f"""
    SELECT *
    FROM `{replies_table}`
    WHERE config_name = @config_name AND status = 'open'
    """
    job = client.query(query, job_config=bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter(
            "config_name", "STRING", config_name)],
    ))
    return [dict(r.items()) for r in job.result()]


def insert_reply(client: bigquery.Client, replies_table: str, *,
                 incident_slack_ts: str, config_name: str,
                 dimension_split_value: str, forecast_method: str,
                 slack_ts: str, slack_channel_id: str,
                 anomaly_type_lower_higher: str,
                 last_anomaly_timestamp: datetime.datetime,
                 now: datetime.datetime, client_msg_id: str) -> None:
    # DML INSERT (not streaming) so rows are immediately eligible for UPDATE.
    query = f"""
    INSERT INTO `{replies_table}` (
      incident_slack_ts, config_name, dimension_split_value, forecast_method,
      slack_ts, slack_channel_id, anomaly_type_lower_higher,
      last_anomaly_timestamp, status, opened_at, last_updated_at, client_msg_id
    )
    VALUES (
      @incident_slack_ts, @config_name, @dimension_split_value, @forecast_method,
      @slack_ts, @slack_channel_id, @anomaly_type_lower_higher,
      @last_anomaly_timestamp, 'open', @now, @now, @client_msg_id
    )
    """
    params = [
        bigquery.ScalarQueryParameter("incident_slack_ts", "STRING", incident_slack_ts),
        bigquery.ScalarQueryParameter("config_name", "STRING", config_name),
        bigquery.ScalarQueryParameter("dimension_split_value", "STRING", dimension_split_value),
        bigquery.ScalarQueryParameter("forecast_method", "STRING", forecast_method),
        bigquery.ScalarQueryParameter("slack_ts", "STRING", slack_ts),
        bigquery.ScalarQueryParameter("slack_channel_id", "STRING", slack_channel_id),
        bigquery.ScalarQueryParameter("anomaly_type_lower_higher", "STRING", anomaly_type_lower_higher),
        bigquery.ScalarQueryParameter("last_anomaly_timestamp", "TIMESTAMP", last_anomaly_timestamp),
        bigquery.ScalarQueryParameter("now", "TIMESTAMP", now),
        bigquery.ScalarQueryParameter("client_msg_id", "STRING", client_msg_id),
    ]
    client.query(query, job_config=bigquery.QueryJobConfig(
        query_parameters=params)).result()


def update_reply(client: bigquery.Client, replies_table: str, *,
                 slack_ts: str, now: datetime.datetime,
                 anomaly_type_lower_higher: str | None = None,
                 status: str | None = None,
                 last_anomaly_timestamp: datetime.datetime | None = None) -> None:
    sets = ["last_updated_at = @now"]
    params = [
        bigquery.ScalarQueryParameter("slack_ts", "STRING", slack_ts),
        bigquery.ScalarQueryParameter("now", "TIMESTAMP", now),
    ]
    if anomaly_type_lower_higher is not None:
        sets.append("anomaly_type_lower_higher = @type")
        params.append(bigquery.ScalarQueryParameter(
            "type", "STRING", anomaly_type_lower_higher))
    if status is not None:
        sets.append("status = @status")
        params.append(bigquery.ScalarQueryParameter("status", "STRING", status))
    if last_anomaly_timestamp is not None:
        sets.append("last_anomaly_timestamp = @ts")
        params.append(bigquery.ScalarQueryParameter(
            "ts", "TIMESTAMP", last_anomaly_timestamp))
    query = (f"UPDATE `{replies_table}` SET " + ", ".join(sets) +
             " WHERE slack_ts = @slack_ts")
    client.query(query, job_config=bigquery.QueryJobConfig(
        query_parameters=params)).result()


def new_client_msg_id() -> str:
    return str(uuid.uuid4())
