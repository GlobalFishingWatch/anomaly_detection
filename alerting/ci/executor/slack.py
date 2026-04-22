"""Slack rendering + API wrappers.

Rendering functions return plain text. API wrappers post or edit messages
and translate Slack error types into outcomes the caller can react to
(e.g. message_not_found -> treat the incident as externally closed).
"""

from __future__ import annotations

import json
import logging
import urllib.parse

from slack_sdk.errors import SlackApiError


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


def render_summary(environment: str, config_name: str, description: str | None,
                   counts: dict, looker_url: str) -> str:
    """Top-level parent message. Edited in place via chat.update as counts change."""
    total = sum(counts.values())
    emoji = ":red_circle:" if (counts.get("critical_higher", 0) + counts.get("critical_lower", 0)) > 0 \
            else ":large_yellow_circle:" if total > 0 else ":large_green_circle:"
    env_line = f"\n*Environment*: {environment}" if environment != "prod" else ""
    desc = description or "No description available"
    # simple 2x2 table
    table = (
        "```\n"
        "            | higher | lower |\n"
        f"  critical  | {counts.get('critical_higher', 0):>6} | {counts.get('critical_lower', 0):>5} |\n"
        f"  warning   | {counts.get('warning_higher', 0):>6} | {counts.get('warning_lower', 0):>5} |\n"
        "```"
    )
    return (
        f"{emoji}\n"
        f"*Anomaly*: {config_name}\n"
        f"*URL*: <{looker_url}|Anomaly Detection Dashboard>\n"
        f"*Active anomalies*: {total}\n"
        f"{table}\n"
        f"*Description*: {desc}"
        f"{env_line}"
    )


def render_dimension_card(row: dict, looker_url: str) -> str:
    """One thread reply, per-dimension. Edited in place on classification change."""
    anomaly_type_lh = row["anomaly_type_lower_higher"]
    emoji = _EMOJI.get(anomaly_type_lh, ":grey_question:")
    dim = row.get("dimension_split_value") or ""
    dim_line = f"\n*Dimension*: {dim}" if dim else ""
    query = row.get("source_sql") or ""
    query_block = f"\n*Query*:\n```\nSELECT{query}\n```" if query else ""
    return (
        f"{emoji}{dim_line}\n"
        f"*URL*: <{looker_url}|Anomaly Detection Dashboard>\n"
        f"*Level*: {anomaly_type_lh}\n"
        f"*Timestamp*: {row['timestamp']}\n"
        f"*Forecast*: {row.get('forecast_value')} ({row.get('forecast_method')})\n"
        f"*Actual*: {row.get('actual_value')}\n"
        f"*Relative delta*: {row.get('delta_rel')}\n"
        f"*Threshold exceeded*: {row.get('exceeded_threshold_lower_higher')}"
        f"{query_block}"
    )


def render_resolved_card(previous_card: str, previous_type: str) -> str:
    """Replace the first emoji with green-circle and add a resolved marker.
    Keeps the original content readable for audit."""
    # drop leading emoji line, prepend resolved marker
    _, _, rest = previous_card.partition("\n")
    return (
        ":large_green_circle: *Resolved* (was " + previous_type + ")\n"
        + rest
    )


def render_closed_summary(previous_summary: str, reason: str) -> str:
    _, _, rest = previous_summary.partition("\n")
    return (
        f":white_check_mark: *Incident closed* ({reason})\n"
        + rest
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


def update_message(slack_client, channel_id: str, ts: str, text: str) -> bool:
    """Edit an existing message. Returns True on success, False if the message
    is gone (deleted / channel archived). Raises other Slack errors."""
    try:
        slack_client.chat_update(channel=channel_id, ts=ts, text=text)
        return True
    except SlackApiError as e:
        err = (e.response or {}).get("error", "")
        if err in ("message_not_found", "channel_not_found", "is_archived"):
            logging.warning("chat_update soft-failed: %s (ts=%s)", err, ts)
            return False
        raise
