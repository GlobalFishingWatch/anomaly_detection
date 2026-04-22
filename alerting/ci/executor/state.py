"""State machine for the threaded-alerting flow.

Pure functions over plain dicts / dataclasses. No I/O -- unit-testable in
isolation. The caller (main.py) translates the returned actions into Slack
and BigQuery operations via bq.py and slack.py.
"""

from __future__ import annotations

import dataclasses
import datetime
from collections import Counter
from typing import Any

# --- actions -----------------------------------------------------------

@dataclasses.dataclass
class OpenIncident:
    config_name: str
    slack_channel_id: str


@dataclasses.dataclass
class CreateReply:
    config_name: str
    slack_channel_id: str
    dimension_split_value: str
    forecast_method: str
    anomaly_type_lower_higher: str
    deltas_row: dict


@dataclasses.dataclass
class UpdateReplyClassification:
    reply_slack_ts: str
    slack_channel_id: str
    dimension_split_value: str
    new_anomaly_type_lower_higher: str
    deltas_row: dict


@dataclasses.dataclass
class ResolveReply:
    reply_slack_ts: str
    slack_channel_id: str
    dimension_split_value: str
    previous_anomaly_type_lower_higher: str


@dataclasses.dataclass
class UpdateParentSummary:
    # None when an OpenIncident is scheduled earlier in the same batch;
    # main.py fills the real ts in after OpenIncident is applied.
    incident_slack_ts: str | None
    slack_channel_id: str
    config_name: str
    counts: dict


@dataclasses.dataclass
class CloseIncident:
    incident_slack_ts: str
    slack_channel_id: str
    config_name: str
    reason: str   # 'all_resolved' | 'timeout' | 'hard_cap'


# --- policy knobs ------------------------------------------------------

DEFAULT_TIMEOUT_HOURS = 24
HARD_CAP_HOURS = 7 * 24


# --- helpers -----------------------------------------------------------

def _reply_key(r: dict) -> tuple[str, str]:
    return (r["dimension_split_value"] or "", r["forecast_method"] or "")


def _row_key(r: dict) -> tuple[str, str]:
    return (r["dimension_split_value"] or "", r["forecast_method"] or "")


def _summary_counts(rows_by_key: dict) -> dict:
    """Count open (non-resolved) replies across lower/higher x critical/warning."""
    counts = Counter()
    for _, row in rows_by_key.items():
        t = row["anomaly_type_lower_higher"]
        if t and t != "normal":
            counts[t] += 1
    return {
        "critical_higher": counts.get("critical_higher", 0),
        "critical_lower": counts.get("critical_lower", 0),
        "warning_higher": counts.get("warning_higher", 0),
        "warning_lower": counts.get("warning_lower", 0),
    }


def _is_stale(incident: dict, now: datetime.datetime, timeout_hours: int) -> str | None:
    """Return a close reason if the incident should be closed by time, else None."""
    opened = incident["opened_at"]
    last_activity = incident.get("last_activity_at") or opened
    age_s = (now - opened).total_seconds()
    idle_s = (now - last_activity).total_seconds()
    if age_s >= HARD_CAP_HOURS * 3600:
        return "hard_cap"
    if idle_s >= timeout_hours * 3600:
        return "timeout"
    return None


# --- main entry point --------------------------------------------------

def process_config(
    config_name: str,
    slack_channel_id: str,
    thread_timeout_hours: int,
    deltas_rows: list[dict],
    open_incident: dict | None,
    open_replies: list[dict],
    now: datetime.datetime,
) -> list[Any]:
    """Decide the actions to take for one config.

    Inputs:
      deltas_rows: rows from t_{env}_deltas for this config, last 30 days.
                   Must include rows where anomaly_type='normal' for any
                   (dim, method) that has an open reply (for resolution).
      open_incident: the currently-open incident for this config, or None.
      open_replies: list of currently-open replies under that incident.

    Returns a list of action dataclasses in the order they should be applied.
    """
    timeout = thread_timeout_hours or DEFAULT_TIMEOUT_HOURS

    # 1. If an incident is open, decide if it's stale and should close.
    if open_incident is not None:
        stale = _is_stale(open_incident, now, timeout)
        if stale == "hard_cap":
            # Force close regardless of state.
            return [CloseIncident(
                incident_slack_ts=open_incident["slack_ts"],
                slack_channel_id=open_incident["slack_channel_id"],
                config_name=config_name,
                reason="hard_cap",
            )]

    # 2. Collapse deltas rows to the latest state per (dim, method).
    #    Multiple rows for the same key happen when multiple timestamps
    #    are anomalous in the window; we take the most recent.
    latest_by_key: dict[tuple[str, str], dict] = {}
    for row in deltas_rows:
        k = _row_key(row)
        prev = latest_by_key.get(k)
        if prev is None or row["timestamp"] > prev["timestamp"]:
            latest_by_key[k] = row

    # 3. Index open replies by their key.
    replies_by_key: dict[tuple[str, str], dict] = {
        _reply_key(r): r for r in open_replies
    }

    actions: list[Any] = []

    # 4. Decide whether to open a new incident. We only open if there's at
    #    least one anomalous row AND no open incident.
    has_anomaly = any(
        r["anomaly_type_lower_higher"] and r["anomaly_type_lower_higher"] != "normal"
        for r in latest_by_key.values()
    )

    incident_slack_ts = open_incident["slack_ts"] if open_incident else None
    if has_anomaly and open_incident is None:
        actions.append(OpenIncident(
            config_name=config_name,
            slack_channel_id=slack_channel_id,
        ))
        # Subsequent reply/update actions reference the incident via a
        # sentinel None slack_ts; main.py fills it in after OpenIncident
        # is applied.
        incident_slack_ts = None

    # 5. For each anomalous row, either create a reply or update its state.
    for key, row in sorted(latest_by_key.items()):
        current_type = row["anomaly_type_lower_higher"]
        existing = replies_by_key.get(key)

        if current_type and current_type != "normal":
            if existing is None:
                actions.append(CreateReply(
                    config_name=config_name,
                    slack_channel_id=slack_channel_id,
                    dimension_split_value=key[0],
                    forecast_method=key[1],
                    anomaly_type_lower_higher=current_type,
                    deltas_row=row,
                ))
            elif existing["anomaly_type_lower_higher"] != current_type:
                actions.append(UpdateReplyClassification(
                    reply_slack_ts=existing["slack_ts"],
                    slack_channel_id=existing["slack_channel_id"],
                    dimension_split_value=key[0],
                    new_anomaly_type_lower_higher=current_type,
                    deltas_row=row,
                ))
            # else: no change, no action
        else:
            # Current state is normal; resolve any open reply.
            if existing is not None:
                actions.append(ResolveReply(
                    reply_slack_ts=existing["slack_ts"],
                    slack_channel_id=existing["slack_channel_id"],
                    dimension_split_value=key[0],
                    previous_anomaly_type_lower_higher=existing["anomaly_type_lower_higher"],
                ))

    # 6. Compute the new summary counts by projecting the actions onto the
    #    current reply state. The summary reflects what the thread will
    #    look like *after* these actions are applied.
    projected = {k: dict(v) for k, v in replies_by_key.items()}
    for a in actions:
        if isinstance(a, CreateReply):
            projected[(a.dimension_split_value, a.forecast_method)] = {
                "anomaly_type_lower_higher": a.anomaly_type_lower_higher,
            }
        elif isinstance(a, UpdateReplyClassification):
            key = (a.dimension_split_value, projected.get(
                (a.dimension_split_value, ""), {}).get("forecast_method", ""))
            # simpler: just iterate replies_by_key
            for k in projected:
                if projected[k].get("slack_ts") == a.reply_slack_ts:
                    projected[k]["anomaly_type_lower_higher"] = a.new_anomaly_type_lower_higher
        elif isinstance(a, ResolveReply):
            for k in projected:
                if projected[k].get("slack_ts") == a.reply_slack_ts:
                    projected[k]["anomaly_type_lower_higher"] = "normal"

    new_counts = _summary_counts(projected)
    prev_counts = {}
    if open_incident and open_incident.get("summary_counts_json"):
        import json
        try:
            prev_counts = json.loads(open_incident["summary_counts_json"])
        except (ValueError, TypeError):
            prev_counts = {}

    if has_anomaly and new_counts != prev_counts:
        actions.append(UpdateParentSummary(
            incident_slack_ts=incident_slack_ts,  # None if a new OpenIncident is pending
            slack_channel_id=slack_channel_id,
            config_name=config_name,
            counts=new_counts,
        ))

    # 7. If all projected replies are 'normal', close the incident.
    all_resolved = all(
        p.get("anomaly_type_lower_higher") in (None, "normal")
        for p in projected.values()
    )
    if open_incident is not None and all_resolved and len(projected) > 0:
        actions.append(CloseIncident(
            incident_slack_ts=open_incident["slack_ts"],
            slack_channel_id=slack_channel_id,
            config_name=config_name,
            reason="all_resolved",
        ))

    # 8. Stale incident: close on timeout. Skip if we've already queued
    #    a close action (all_resolved or hard_cap) earlier.
    already_closing = any(isinstance(a, CloseIncident) for a in actions)
    if open_incident is not None and not already_closing:
        stale = _is_stale(open_incident, now, timeout)
        if stale == "timeout":
            actions.append(CloseIncident(
                incident_slack_ts=open_incident["slack_ts"],
                slack_channel_id=slack_channel_id,
                config_name=config_name,
                reason="timeout",
            ))

    return actions
