"""Slack rendering + API wrappers (v2: post-only).

All callers emit new messages via chat.postMessage. No chat.update paths
remain -- the thread itself is the timeline.
"""

from __future__ import annotations

import datetime
import json
import urllib.parse


# --- rendering ---------------------------------------------------------

_EMOJI = {
    "critical_higher": ":red_circle:",
    "critical_lower": ":red_circle:",
    "warning_higher": ":large_yellow_circle:",
    "warning_lower": ":large_yellow_circle:",
    "normal": ":large_green_circle:",
}


def make_looker_studio_url(report_id: str, page_id: str, config_name: str,
                           forecast_method: str, dimension: str) -> str:
    params = {
        "PARAM_CONFIG_NAME": config_name,
        "PARAM_FC": forecast_method,
        "PARAM_DIMENSION": dimension,
    }
    encoded = urllib.parse.quote(json.dumps(params))
    return (f"https://lookerstudio.google.com/reporting/{report_id}"
            f"/page/{page_id}?params={encoded}")


def render_thread_opener(config_name: str, anomaly_date: datetime.date,
                         environment: str,
                         description: str | None,
                         looker_url: str) -> str:
    """Static parent message. Posted once; never edited."""
    env_line = f"\n*Environment*: {environment}" if environment != "prod" else ""
    desc = description or "No description available"
    return (
        f":rotating_light: *Incident*: `{config_name}`\n"
        f"*Data date*: `{anomaly_date.isoformat()}`\n"
        f"*Dashboard*: <{looker_url}|Anomaly Detection>"
        f"{env_line}\n"
        f"_{desc}_"
    )


def render_fire(row: dict, looker_url: str) -> str:
    """Initial fire for a (dim, method)."""
    anomaly_type_lh = row["anomaly_type_lower_higher"]
    emoji = _EMOJI.get(anomaly_type_lh, ":grey_question:")
    dim = row.get("dimension_split_value") or ""
    dim_line = f"\n*Dimension*: `{dim}`" if dim else ""
    method = row.get("forecast_method")
    query = row.get("source_sql") or ""
    query_block = f"\n*Query*:\n```\nSELECT{query}\n```" if query else ""
    return (
        f"{emoji} *New*: {anomaly_type_lh}{dim_line}\n"
        f"*Method*: {method}\n"
        f"*Timestamp*: {row['timestamp']}\n"
        f"*Forecast*: {row.get('forecast_value')}\n"
        f"*Actual*: {row.get('actual_value')}\n"
        f"*Relative delta*: {row.get('delta_rel')}\n"
        f"*Dashboard*: <{looker_url}|drill in>"
        f"{query_block}"
    )


def render_severity_change(row: dict, previous_type: str, new_type: str,
                           looker_url: str) -> str:
    """Bucket flip. Keep it compact: emojis on both sides + numerics."""
    prev_emoji = _EMOJI.get(previous_type, ":grey_question:")
    new_emoji = _EMOJI.get(new_type, ":grey_question:")
    dim = row.get("dimension_split_value") or ""
    dim_line = f" `{dim}`" if dim else ""
    return (
        f"{prev_emoji}→{new_emoji} *Severity change*{dim_line}: "
        f"{previous_type} → *{new_type}*\n"
        f"*Timestamp*: {row['timestamp']}\n"
        f"*Forecast*: {row.get('forecast_value')}, "
        f"*Actual*: {row.get('actual_value')}, "
        f"*Relative delta*: {row.get('delta_rel')}\n"
        f"*Dashboard*: <{looker_url}|drill in>"
    )


def render_resolve(previous_type: str, dim: str | None) -> str:
    dim_part = f" `{dim}`" if dim else ""
    return (
        f":large_green_circle: *Resolved*{dim_part} "
        f"(was {previous_type})"
    )


def render_summary(counts: dict) -> str:
    """Aggregate state snapshot. Posted once per thread per run if counts
    changed. Never includes a zero-state: the caller guarantees at least
    one non-zero count before emitting."""
    total = sum(counts.values())
    table = (
        "```\n"
        "          | higher | lower |\n"
        f" critical | {counts.get('critical_higher', 0):>6} | {counts.get('critical_lower', 0):>5} |\n"
        f" warning  | {counts.get('warning_higher', 0):>6} | {counts.get('warning_lower', 0):>5} |\n"
        "```"
    )
    return (
        f":bar_chart: *Summary* ({total} active)\n"
        f"{table}"
    )


def render_closed(reason: str) -> str:
    return (
        f":white_check_mark: *Incident closed* ({reason})"
    )


# --- API wrappers -------------------------------------------------------

def post_parent(slack_client, channel_id: str, text: str) -> str:
    r = slack_client.chat_postMessage(channel=channel_id, text=text, unfurl_links=False)
    return r["ts"]


def post_reply(slack_client, channel_id: str, thread_ts: str, text: str) -> str:
    r = slack_client.chat_postMessage(
        channel=channel_id, thread_ts=thread_ts, text=text, unfurl_links=False,
    )
    return r["ts"]
