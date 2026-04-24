"""State machine for the threaded-alerting flow (v2: data-date + append-only).

Pure functions over plain dicts / dataclasses. No I/O -- unit-testable.
Thread identity is (config_name, anomaly_date). Every state transition emits
a new Slack reply; nothing is ever edited. A single summary-reply per thread
per run carries the aggregate counts (debounced against the last posted
summary).
"""

from __future__ import annotations

import dataclasses
import datetime
import json
from collections import Counter
from typing import Any

# --- actions -----------------------------------------------------------

@dataclasses.dataclass
class OpenThread:
    config_name: str
    anomaly_date: datetime.date
    slack_channel_id: str
    description: str | None
    # Aggregate severity across the firing rows at open time. One of
    # 'critical' | 'warning' | 'normal'. Drives the opener emoji.
    severity: str = "normal"
    # First firing row details. Populated for flat / flat-with-resolve-replies
    # modes so the opener itself renders as a rich fire card. None for the
    # default 'thread' mode, which keeps the opener slim.
    first_fire_row: dict | None = None


@dataclasses.dataclass
class PostFire:
    # incident_slack_ts is None when an OpenThread is scheduled earlier in
    # the same batch; main.py fills the real ts in after OpenThread is
    # applied.
    incident_slack_ts: str | None
    slack_channel_id: str
    config_name: str
    dimension_split_value: str
    forecast_method: str
    anomaly_type_lower_higher: str
    deltas_row: dict


@dataclasses.dataclass
class PostSeverityChange:
    incident_slack_ts: str
    slack_channel_id: str
    config_name: str
    dimension_split_value: str
    forecast_method: str
    previous_anomaly_type_lower_higher: str
    new_anomaly_type_lower_higher: str
    deltas_row: dict


@dataclasses.dataclass
class PostResolve:
    incident_slack_ts: str
    slack_channel_id: str
    config_name: str
    dimension_split_value: str
    forecast_method: str
    previous_anomaly_type_lower_higher: str


@dataclasses.dataclass
class PostSummary:
    incident_slack_ts: str | None
    slack_channel_id: str
    config_name: str
    anomaly_date: datetime.date
    counts: dict


@dataclasses.dataclass
class CloseThread:
    incident_slack_ts: str
    slack_channel_id: str
    config_name: str
    anomaly_date: datetime.date
    reason: str   # 'all_resolved' | 'hard_cap'


# --- policy knobs ------------------------------------------------------

HARD_CAP_HOURS = 7 * 24


# --- aggregation mode --------------------------------------------------

# Per-config output shape. Decision rule (see analysis/alerting_v2_1_plan.md):
# dimension_split present -> thread; no dim_split + daily -> flat;
# no dim_split + hourly -> flat-with-resolve-replies. Configs absent from
# this dict fall back to 'thread'.
AGGREGATION_MODE: dict[str, str] = {
    # flat: opener IS the alert; no fires, no summary reply.
    "parser_errors_daily": "flat",
    "pipe3_gaps": "flat",
    "pipe3_vs_pipe2_5_published_fishing_effort_deltas": "flat",
    "pipe3_vs_pipe2_5_published_fishing_events_deltas": "flat",
    "pipe3_vs_pipe2_5_published_fishing_events_duration_deltas": "flat",
    "t_world_fishing_827_queries_billed": "flat",
    "s2_index_delays": "flat",
    "s2_published_detections_delays": "flat",
    "pipe3_product_events_fishing_count_esp": "flat",
    # flat-with-resolve-replies: opener carries initial alert; severity
    # changes and resolve still post as replies.
    "parsed_row_count_hourly": "flat-with-resolve-replies",
    "pipe3_product_events_fishing_count": "flat-with-resolve-replies",
}


def _aggregation_mode(config_name: str) -> str:
    return AGGREGATION_MODE.get(config_name, "thread")


_SEVERITY_PREFIXES = {
    "critical_higher": "critical",
    "critical_lower": "critical",
    "warning_higher": "warning",
    "warning_lower": "warning",
}


def _max_severity(rows: list[dict]) -> str:
    """Collapse a batch of firing rows to a single severity label.
    critical > warning > normal."""
    severities = {
        _SEVERITY_PREFIXES.get(r.get("anomaly_type_lower_higher") or "", "normal")
        for r in rows
    }
    if "critical" in severities:
        return "critical"
    if "warning" in severities:
        return "warning"
    return "normal"


def _filter_for_flat_mode(actions: list[Any], mode: str) -> list[Any]:
    """Drop action types per the aggregation mode table:

        thread                   -> all actions kept
        flat-with-resolve-replies -> keep OpenThread, PostSeverityChange,
                                     PostResolve, CloseThread
        flat                     -> keep OpenThread, CloseThread only
    """
    if mode == "thread":
        return actions
    if mode == "flat-with-resolve-replies":
        allowed: tuple[type, ...] = (
            OpenThread, PostSeverityChange, PostResolve, CloseThread,
        )
    elif mode == "flat":
        allowed = (OpenThread, CloseThread)
    else:
        return actions
    return [a for a in actions if isinstance(a, allowed)]


# --- helpers -----------------------------------------------------------

def _key(dim: str | None, method: str | None) -> tuple[str, str]:
    return (dim or "", method or "")


def _latest_state_from_events(events: list[dict]) -> dict[tuple[str, str], dict]:
    """Given the append-only event log for a thread, return the latest
    announced state per (dim, method). Ignores 'summary' events."""
    out: dict[tuple[str, str], dict] = {}
    for ev in events:
        if ev.get("kind") == "summary":
            continue
        k = _key(ev.get("dimension_split_value"), ev.get("forecast_method"))
        prev = out.get(k)
        if prev is None or ev["posted_at"] > prev["posted_at"]:
            out[k] = ev
    return out


def _count(reply_states: dict[tuple[str, str], dict]) -> dict:
    """Count non-resolved anomaly buckets across the current reply states."""
    c = Counter()
    for ev in reply_states.values():
        t = ev.get("anomaly_type_lower_higher")
        if t and t != "normal":
            c[t] += 1
    return {
        "critical_higher": c.get("critical_higher", 0),
        "critical_lower": c.get("critical_lower", 0),
        "warning_higher": c.get("warning_higher", 0),
        "warning_lower": c.get("warning_lower", 0),
    }


def _hard_cap_reached(incident: dict, now: datetime.datetime) -> bool:
    opened = incident["opened_at"]
    return (now - opened).total_seconds() >= HARD_CAP_HOURS * 3600


# --- main entry point --------------------------------------------------

def process_thread(
    *,
    config_name: str,
    anomaly_date: datetime.date,
    slack_channel_id: str,
    deltas_rows: list[dict],
    open_incident: dict | None,
    reply_events: list[dict],
    now: datetime.datetime,
    description: str | None = None,
) -> list[Any]:
    """Decide the actions for one (config, anomaly_date) thread.

    Inputs:
      deltas_rows: rows from t_{env}_deltas for this (config, date).
                   The caller should pass the LATEST row per (dim, method).
      open_incident: the currently-open incident for (config, date), or None.
      reply_events: the append-only event log for that incident.
    """
    # 1. Hard-cap: close unconditionally if we're past the cap.
    if open_incident is not None and _hard_cap_reached(open_incident, now):
        return [CloseThread(
            incident_slack_ts=open_incident["slack_ts"],
            slack_channel_id=open_incident["slack_channel_id"],
            config_name=config_name,
            anomaly_date=anomaly_date,
            reason="hard_cap",
        )]

    # 2. Collapse deltas rows to the latest per (dim, method).
    latest_by_key: dict[tuple[str, str], dict] = {}
    for row in deltas_rows:
        k = _key(row.get("dimension_split_value"), row.get("forecast_method"))
        prev = latest_by_key.get(k)
        if prev is None or row["timestamp"] > prev["timestamp"]:
            latest_by_key[k] = row

    # 3. Derive current announced state per (dim, method) from the event log.
    announced = _latest_state_from_events(reply_events)

    has_anomaly = any(
        r.get("anomaly_type_lower_higher") and r["anomaly_type_lower_higher"] != "normal"
        for r in latest_by_key.values()
    )

    actions: list[Any] = []

    # 4. Open thread if there's an anomaly and no incident yet. Subsequent
    #    PostFire / PostSummary reference this via a sentinel None slack_ts;
    #    the orchestrator patches it in after OpenThread is applied.
    if has_anomaly and open_incident is None:
        firing_rows = [
            r for r in latest_by_key.values()
            if r.get("anomaly_type_lower_higher")
            and r["anomaly_type_lower_higher"] != "normal"
        ]
        severity = _max_severity(firing_rows)
        first_fire_row = (
            min(firing_rows, key=lambda r: (r["timestamp"],
                                             r.get("dimension_split_value") or "",
                                             r.get("forecast_method") or ""))
            if firing_rows else None
        )
        actions.append(OpenThread(
            config_name=config_name,
            anomaly_date=anomaly_date,
            slack_channel_id=slack_channel_id,
            description=description,
            severity=severity,
            first_fire_row=first_fire_row,
        ))
        incident_slack_ts = None
    else:
        incident_slack_ts = open_incident["slack_ts"] if open_incident else None

    # 5. Per (dim, method), emit PostFire / PostSeverityChange / PostResolve.
    #    Value-invariance: if the latest bucket matches what we last
    #    announced, emit nothing.
    for key, row in sorted(latest_by_key.items()):
        current_type = row.get("anomaly_type_lower_higher")
        last = announced.get(key)
        last_type = last.get("anomaly_type_lower_higher") if last else None
        last_kind = last.get("kind") if last else None

        # "Announced state" treats a 'resolve' event as normal.
        effective_last_type = last_type if last_kind != "resolve" else "normal"

        if current_type and current_type != "normal":
            if effective_last_type in (None, "normal"):
                actions.append(PostFire(
                    incident_slack_ts=incident_slack_ts,
                    slack_channel_id=slack_channel_id,
                    config_name=config_name,
                    dimension_split_value=key[0],
                    forecast_method=key[1],
                    anomaly_type_lower_higher=current_type,
                    deltas_row=row,
                ))
            elif effective_last_type != current_type:
                actions.append(PostSeverityChange(
                    incident_slack_ts=incident_slack_ts,  # type: ignore[arg-type]
                    slack_channel_id=slack_channel_id,
                    config_name=config_name,
                    dimension_split_value=key[0],
                    forecast_method=key[1],
                    previous_anomaly_type_lower_higher=effective_last_type,
                    new_anomaly_type_lower_higher=current_type,
                    deltas_row=row,
                ))
            # else: same bucket, no action (value-invariance)
        else:
            if effective_last_type and effective_last_type != "normal":
                actions.append(PostResolve(
                    incident_slack_ts=incident_slack_ts,  # type: ignore[arg-type]
                    slack_channel_id=slack_channel_id,
                    config_name=config_name,
                    dimension_split_value=key[0],
                    forecast_method=key[1],
                    previous_anomaly_type_lower_higher=effective_last_type,
                ))

    # 6. Compute the new summary counts by projecting the new actions onto
    #    the announced state. Debounce: only emit PostSummary if counts
    #    differ from the last-posted summary.
    projected = {k: dict(v) for k, v in announced.items()}
    # Treat 'resolve' as normal for projection.
    for k, v in projected.items():
        if v.get("kind") == "resolve":
            v["anomaly_type_lower_higher"] = "normal"
    for a in actions:
        if isinstance(a, PostFire):
            projected[_key(a.dimension_split_value, a.forecast_method)] = {
                "anomaly_type_lower_higher": a.anomaly_type_lower_higher,
            }
        elif isinstance(a, PostSeverityChange):
            projected[_key(a.dimension_split_value, a.forecast_method)] = {
                "anomaly_type_lower_higher": a.new_anomaly_type_lower_higher,
            }
        elif isinstance(a, PostResolve):
            projected[_key(a.dimension_split_value, a.forecast_method)] = {
                "anomaly_type_lower_higher": "normal",
            }

    new_counts = _count(projected)

    last_posted_counts = {}
    if open_incident and open_incident.get("summary_counts_json"):
        try:
            last_posted_counts = json.loads(open_incident["summary_counts_json"])
        except (ValueError, TypeError):
            last_posted_counts = {}

    emitted_any_transition = any(
        isinstance(a, (PostFire, PostSeverityChange, PostResolve))
        for a in actions
    )

    if emitted_any_transition and new_counts != last_posted_counts:
        actions.append(PostSummary(
            incident_slack_ts=incident_slack_ts,
            slack_channel_id=slack_channel_id,
            config_name=config_name,
            anomaly_date=anomaly_date,
            counts=new_counts,
        ))

    # 7. Close thread when all dimensions are resolved. Only meaningful if
    #    there's an open incident AND at least one announced dim AND all
    #    projected states are normal.
    if open_incident is not None and len(projected) > 0 and all(
        p.get("anomaly_type_lower_higher") in (None, "normal")
        for p in projected.values()
    ):
        actions.append(CloseThread(
            incident_slack_ts=open_incident["slack_ts"],
            slack_channel_id=slack_channel_id,
            config_name=config_name,
            anomaly_date=anomaly_date,
            reason="all_resolved",
        ))

    # 8. Apply the per-config aggregation-mode filter. For flat modes this
    #    drops the action types that the config does not want to see as
    #    thread replies. The opener (if any) already carries the first
    #    firing row's details for these modes, so the channel scanner still
    #    sees the critical numbers at a glance.
    return _filter_for_flat_mode(actions, _aggregation_mode(config_name))
