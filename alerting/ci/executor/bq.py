"""BigQuery queries and writes for the threaded-alerting flow (v2).

All Slack-writing callers should go through these helpers so the SQL is in
one place. Writes use DML `INSERT INTO ... VALUES (...)` executed as query
jobs rather than streaming inserts -- DML lands rows in managed storage
immediately, avoiding the 30-90 minute streaming buffer window during
which UPDATE/DELETE on newly-inserted rows is rejected.

Table names supplied by the caller (CLI args) are canonicalized through
`canonical_table_id()` before being interpolated into SQL to prevent
identifier injection.

Replies are append-only in v2: `insert_reply_event()` only inserts, never
updates. Deriving "current state of dim X in thread Y" is a query against
the event log (latest non-summary row per (dim, method)).
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
    """Look up slack_channel_id for a (config, env) using the two-tier
    fallback: exact (config, env) match > env-only fallback row
    (config_name IS NULL). Raises ValueError when neither exists -- an
    unmapped config must never be routed to an arbitrary channel."""
    query = f"""
    SELECT
      CASE
        WHEN config_name = @config_name AND environment = @environment THEN 1
        WHEN config_name IS NULL AND environment = @environment THEN 2
      END AS priority,
      slack_channel_id,
      slack_channel_name
    FROM `{CHANNEL_MAPPING_TABLE}`
    WHERE (config_name = @config_name AND environment = @environment)
       OR (config_name IS NULL AND environment = @environment)
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
        raise ValueError(
            f"No Slack channel mapping for {config_name}/{environment} -- "
            f"add an exact row or an env-level fallback (config_name=NULL) "
            f"to {CHANNEL_MAPPING_TABLE}")
    r = rows[0]
    return {
        "slack_channel_id": r["slack_channel_id"],
        "slack_channel_name": r["slack_channel_name"],
    }


# --- deltas query ------------------------------------------------------

def query_deltas_with_open_incidents(
    client: bigquery.Client, environment: str, incidents_table: str,
) -> list[dict]:
    """Return the latest deltas row per (config, DATE(timestamp), dim, method)
    for any key that either was anomalous in the last 30 days or belongs to
    an open incident's (config, anomaly_date).

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
                      DATE(timestamp) AS anomaly_date,
                      IFNULL(dimension_split_value, '') AS dimension_split_value,
                      forecast_method
      FROM `{deltas}`
      WHERE anomaly_type != 'normal'
        AND timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30*24 HOUR)
      UNION DISTINCT
      -- Any (config, anomaly_date) with an open incident: pull in ALL dims
      -- that might need a resolution check. We widen by joining back to
      -- deltas on (config, date) and picking anything that has ever been
      -- anomalous in that day.
      SELECT DISTINCT d.config_name,
                      DATE(d.timestamp) AS anomaly_date,
                      IFNULL(d.dimension_split_value, '') AS dimension_split_value,
                      d.forecast_method
      FROM `{deltas}` d
      JOIN `{incidents_table}` i
        ON d.config_name = i.config_name
       AND DATE(d.timestamp) = i.anomaly_date
      WHERE i.status = 'open'
        AND d.anomaly_type != 'normal'
    )
    SELECT d.*, DATE(d.timestamp) AS anomaly_date
    FROM `{deltas}` d
    JOIN keys_of_interest k
      ON d.config_name = k.config_name
     AND DATE(d.timestamp) = k.anomaly_date
     AND IFNULL(d.dimension_split_value, '') = k.dimension_split_value
     AND d.forecast_method = k.forecast_method
    WHERE d.timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30*24 HOUR)
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY d.config_name, DATE(d.timestamp),
                   IFNULL(d.dimension_split_value, ''), d.forecast_method
      ORDER BY d.timestamp DESC
    ) = 1
    """
    rows = []
    for r in client.query(query, job_config=bigquery.QueryJobConfig(use_query_cache=False)).result():
        rows.append(dict(r.items()))
    return rows


# --- incidents ---------------------------------------------------------

def find_open_incident(client: bigquery.Client, incidents_table: str,
                       config_name: str,
                       anomaly_date: datetime.date) -> dict | None:
    """Return the currently-open incident for (config, anomaly_date), or
    -- as a duplicate-thread guard -- the most recent resolved incident
    for that key if it was closed within the last 24 hours. In the
    resolved-within-24h case the caller is expected to transition the row
    back to `status='open'` and append new replies to the same Slack
    thread. Past that window a fresh thread is acceptable."""
    query = f"""
    SELECT *
    FROM `{incidents_table}`
    WHERE config_name = @config_name
      AND anomaly_date = @anomaly_date
      AND (
        status = 'open'
        OR (
          status = 'resolved'
          AND closed_at IS NOT NULL
          AND closed_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
        )
      )
    ORDER BY
      CASE WHEN status = 'open' THEN 0 ELSE 1 END,
      opened_at DESC
    LIMIT 1
    """
    job = client.query(query, job_config=bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("config_name", "STRING", config_name),
            bigquery.ScalarQueryParameter("anomaly_date", "DATE", anomaly_date),
        ],
    ))
    rows = list(job.result())
    if not rows:
        return None
    return dict(rows[0].items())


def list_open_incident_keys(
    client: bigquery.Client, incidents_table: str,
) -> list[tuple[str, datetime.date]]:
    """Return (config_name, anomaly_date) pairs for all open incidents, so
    the orchestrator visits them even if no fresh deltas mention them (for
    resolution detection)."""
    query = f"""
    SELECT DISTINCT config_name, anomaly_date
    FROM `{incidents_table}`
    WHERE status = 'open'
    """
    return [(r["config_name"], r["anomaly_date"]) for r in client.query(query).result()]


# --- bootstrap (first-seen-config suppression) ------------------------

# Marker prefix on slack_ts so bootstrap rows are distinguishable from real
# Slack thread parents (which are decimal strings like "1777287766.596539").
BOOTSTRAP_SLACK_TS_PREFIX = "BOOTSTRAP-"


def list_configs_with_any_incident(
    client: bigquery.Client, incidents_table: str,
) -> set[str]:
    """Distinct config_names with at least one row in the incidents table.
    A config absent from this set is being seen for the first time — its
    historical anomalies are silently bootstrapped instead of alerted on."""
    query = (f"SELECT DISTINCT config_name FROM `{incidents_table}` "
             "WHERE config_name IS NOT NULL")
    return {r["config_name"] for r in client.query(query).result()}


def list_bootstrapped_pairs(
    client: bigquery.Client, incidents_table: str,
) -> set[tuple[str, datetime.date]]:
    """(config_name, anomaly_date) pairs already marked as bootstrapped on a
    previous run. The orchestrator drops deltas matching these so they
    never get re-processed."""
    query = (f"SELECT DISTINCT config_name, anomaly_date "
             f"FROM `{incidents_table}` "
             f"WHERE STARTS_WITH(slack_ts, '{BOOTSTRAP_SLACK_TS_PREFIX}')")
    return {(r["config_name"], r["anomaly_date"])
            for r in client.query(query).result()}


def list_silenced_keys(
    client: bigquery.Client, incidents_table: str,
    hard_cap_hours: int,
) -> set[tuple[str, datetime.date]]:
    """(config_name, anomaly_date) pairs whose latest non-bootstrap incident
    is `resolved` and was `opened_at` more than `hard_cap_hours` ago.

    Such pairs have already exhausted their thread lifecycle: the data is
    likely still firing in deltas, but the original Slack thread was closed
    (typically by the hard-cap rule in `state.process_thread`). Without
    this filter, the orchestrator either churns through a [reopen] ->
    CloseThread(hard_cap) pair every run (while `closed_at` is within 24h)
    or spawns a brand-new thread for the same old anomaly_date once
    `closed_at` falls past the 24h `find_open_incident` window. The caller
    drops these pairs at the top of the run so neither happens.
    """
    query = f"""
    WITH latest AS (
      SELECT
        config_name,
        anomaly_date,
        status,
        opened_at,
        ROW_NUMBER() OVER (
          PARTITION BY config_name, anomaly_date
          ORDER BY opened_at DESC
        ) AS rn
      FROM `{incidents_table}`
      WHERE NOT STARTS_WITH(IFNULL(slack_ts, ''), '{BOOTSTRAP_SLACK_TS_PREFIX}')
    )
    SELECT config_name, anomaly_date
    FROM latest
    WHERE rn = 1
      AND status = 'resolved'
      AND opened_at <= TIMESTAMP_SUB(CURRENT_TIMESTAMP(),
                                     INTERVAL @hours HOUR)
    """
    job = client.query(query, job_config=bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("hours", "INT64", hard_cap_hours),
        ],
    ))
    return {(r["config_name"], r["anomaly_date"]) for r in job.result()}


def insert_bootstrap_incident(
    client: bigquery.Client, incidents_table: str, *,
    config_name: str, anomaly_date: datetime.date,
    summary_counts_json: str, now: datetime.datetime,
) -> None:
    """Insert a resolved 'bootstrap' marker for (config, anomaly_date). No
    Slack message exists; slack_ts is a synthetic BOOTSTRAP-prefixed string
    so subsequent runs can identify and skip the pair via
    list_bootstrapped_pairs."""
    slack_ts = (f"{BOOTSTRAP_SLACK_TS_PREFIX}{config_name}-"
                f"{anomaly_date.isoformat()}-{new_client_msg_id()[:8]}")
    query = f"""
    INSERT INTO `{incidents_table}` (
      config_name, anomaly_date, slack_channel_id, slack_ts, opened_at,
      closed_at, status, client_msg_id, summary_counts_json
    )
    VALUES (
      @config_name, @anomaly_date, '', @slack_ts, @now,
      @now, 'resolved', @client_msg_id, @summary_counts_json
    )
    """
    params = [
        bigquery.ScalarQueryParameter("config_name", "STRING", config_name),
        bigquery.ScalarQueryParameter("anomaly_date", "DATE", anomaly_date),
        bigquery.ScalarQueryParameter("slack_ts", "STRING", slack_ts),
        bigquery.ScalarQueryParameter("now", "TIMESTAMP", now),
        bigquery.ScalarQueryParameter("client_msg_id", "STRING", new_client_msg_id()),
        bigquery.ScalarQueryParameter("summary_counts_json", "STRING", summary_counts_json),
    ]
    client.query(query, job_config=bigquery.QueryJobConfig(
        query_parameters=params)).result()


def insert_incident(client: bigquery.Client, incidents_table: str, *,
                    config_name: str, anomaly_date: datetime.date,
                    slack_channel_id: str, slack_ts: str,
                    now: datetime.datetime, summary_counts_json: str,
                    client_msg_id: str) -> None:
    query = f"""
    INSERT INTO `{incidents_table}` (
      config_name, anomaly_date, slack_channel_id, slack_ts, opened_at,
      closed_at, status, client_msg_id, summary_counts_json
    )
    VALUES (
      @config_name, @anomaly_date, @slack_channel_id, @slack_ts, @now,
      NULL, 'open', @client_msg_id, @summary_counts_json
    )
    """
    params = [
        bigquery.ScalarQueryParameter("config_name", "STRING", config_name),
        bigquery.ScalarQueryParameter("anomaly_date", "DATE", anomaly_date),
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
                    closed_at: datetime.datetime | None = None,
                    clear_closed_at: bool = False) -> None:
    sets = []
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
    if clear_closed_at:
        sets.append("closed_at = NULL")
    elif closed_at is not None:
        sets.append("closed_at = @closed_at")
        params.append(bigquery.ScalarQueryParameter("closed_at", "TIMESTAMP", closed_at))
    if not sets:
        return
    query = (f"UPDATE `{incidents_table}` SET " + ", ".join(sets) +
             " WHERE slack_ts = @slack_ts")
    client.query(query, job_config=bigquery.QueryJobConfig(
        query_parameters=params)).result()


# --- reply events (append-only) ---------------------------------------

def find_reply_events(client: bigquery.Client, replies_table: str,
                      incident_slack_ts: str) -> list[dict]:
    """All reply events for a thread, newest last. Used by the state
    machine to derive current state per (dim, method)."""
    query = f"""
    SELECT *
    FROM `{replies_table}`
    WHERE incident_slack_ts = @ts
    ORDER BY posted_at
    """
    job = client.query(query, job_config=bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter(
            "ts", "STRING", incident_slack_ts)],
    ))
    return [dict(r.items()) for r in job.result()]


def insert_reply_event(client: bigquery.Client, replies_table: str, *,
                       incident_slack_ts: str, config_name: str,
                       dimension_split_value: str | None,
                       forecast_method: str | None,
                       slack_ts: str, slack_channel_id: str,
                       kind: str,
                       anomaly_type_lower_higher: str | None,
                       previous_anomaly_type_lower_higher: str | None,
                       anomaly_timestamp: datetime.datetime | None,
                       now: datetime.datetime,
                       client_msg_id: str) -> None:
    """Append a single reply-event row. kind is one of:
    'fire', 'severity_change', 'resolve', 'summary'."""
    query = f"""
    INSERT INTO `{replies_table}` (
      incident_slack_ts, config_name, dimension_split_value, forecast_method,
      slack_ts, slack_channel_id, kind, anomaly_type_lower_higher,
      previous_anomaly_type_lower_higher, anomaly_timestamp, posted_at,
      client_msg_id
    )
    VALUES (
      @incident_slack_ts, @config_name, @dim, @method,
      @slack_ts, @slack_channel_id, @kind, @type,
      @prev_type, @anomaly_timestamp, @now,
      @client_msg_id
    )
    """
    params = [
        bigquery.ScalarQueryParameter("incident_slack_ts", "STRING", incident_slack_ts),
        bigquery.ScalarQueryParameter("config_name", "STRING", config_name),
        bigquery.ScalarQueryParameter("dim", "STRING", dimension_split_value),
        bigquery.ScalarQueryParameter("method", "STRING", forecast_method),
        bigquery.ScalarQueryParameter("slack_ts", "STRING", slack_ts),
        bigquery.ScalarQueryParameter("slack_channel_id", "STRING", slack_channel_id),
        bigquery.ScalarQueryParameter("kind", "STRING", kind),
        bigquery.ScalarQueryParameter("type", "STRING", anomaly_type_lower_higher),
        bigquery.ScalarQueryParameter("prev_type", "STRING", previous_anomaly_type_lower_higher),
        bigquery.ScalarQueryParameter("anomaly_timestamp", "TIMESTAMP", anomaly_timestamp),
        bigquery.ScalarQueryParameter("now", "TIMESTAMP", now),
        bigquery.ScalarQueryParameter("client_msg_id", "STRING", client_msg_id),
    ]
    client.query(query, job_config=bigquery.QueryJobConfig(
        query_parameters=params)).result()


def new_client_msg_id() -> str:
    return str(uuid.uuid4())
