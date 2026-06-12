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

_SEVERITY_EMOJI = {
    "critical": ":red_circle:",
    "warning": ":large_yellow_circle:",
    "normal": ":large_green_circle:",
}


def _render_fire_body(row: dict, looker_url: str) -> str:
    """Body of a fire card (no leading heading line). Shared between
    `render_fire` and the flat-mode opener so the format string isn't
    duplicated. The caller prepends its own heading line (e.g. '*New*: ...'
    or the opener heading)."""
    dim = row.get("dimension_split_value") or ""
    dim_line = f"*Dimension*: `{dim}`\n" if dim else ""
    method = row.get("forecast_method")
    query = row.get("source_sql") or ""
    query_block = f"\n*Query*:\n```\nSELECT{query}\n```" if query else ""
    return (
        f"{dim_line}"
        f"*Method*: {method}\n"
        f"*Timestamp*: {row['timestamp']}\n"
        f"*Forecast*: {row.get('forecast_value')}\n"
        f"*Actual*: {row.get('actual_value')}\n"
        f"*Relative delta*: {row.get('delta_rel')}\n"
        f"*Dashboard*: <{looker_url}|drill in>"
        f"{query_block}"
    )


# Looker Studio data-source filter delimiter. Internally Looker uses U+E000
# but the dashboard URLs we generate carry it as the URL-encoded literal text
# `%EE%80%80` inside the JSON value -- the surrounding url-quote step then
# turns each `%` into `%25`, giving the `%25EE%2580%2580` you see in the wild.
_LS_FILTER_DELIM = "%EE%80%80"

# Slot ids of the data-source filters on the anomaly-detection Looker Studio
# report. Mirror PARAM_CONFIG_NAME and PARAM_DIMENSION respectively (the
# parameters set the controls; the filters apply them to the data).
_LS_FILTER_CONFIG = "df34"
_LS_FILTER_DIMENSION = "df43"


def make_looker_studio_url(report_id: str, page_id: str, config_name: str,
                           forecast_method: str, dimension: str) -> str:
    """Return a Looker Studio deep-link with both the user-defined parameters
    AND the data-source filters set, so the report opens with rows actually
    filtered to the (config, dim) the alert is about.

    The encoding mirrors what the dashboard UI emits: compact JSON (no spaces),
    `:` and `,` left unencoded in the query string."""
    params: dict[str, str] = {
        "PARAM_CONFIG_NAME": config_name,
        "PARAM_FC": forecast_method,
        "PARAM_DIMENSION": dimension,
    }
    if config_name:
        params[_LS_FILTER_CONFIG] = (
            f"include{_LS_FILTER_DELIM}0{_LS_FILTER_DELIM}IN"
            f"{_LS_FILTER_DELIM}{config_name}"
        )
    if dimension:
        params[_LS_FILTER_DIMENSION] = (
            f"include{_LS_FILTER_DELIM}0{_LS_FILTER_DELIM}IN"
            f"{_LS_FILTER_DELIM}{dimension}"
        )
    encoded = urllib.parse.quote(
        json.dumps(params, separators=(",", ":")),
        safe=":,",
    )
    return (f"https://datastudio.google.com/u/0/reporting/{report_id}"
            f"/page/{page_id}?params={encoded}")


def _render_counts_table(counts: dict) -> str:
    """Shared counts-table block. Used by the opener (frozen-at-open) and
    by in-thread summary replies (current state)."""
    return (
        "```\n"
        "          | higher | lower |\n"
        f" critical | {counts.get('critical_higher', 0):>6} | {counts.get('critical_lower', 0):>5} |\n"
        f" warning  | {counts.get('warning_higher', 0):>6} | {counts.get('warning_lower', 0):>5} |\n"
        "```"
    )


def render_thread_opener(config_name: str, anomaly_date: datetime.date,
                         environment: str,
                         description: str | None,
                         looker_url: str,
                         severity: str = "normal",
                         first_fire_row: dict | None = None,
                         counts: dict | None = None,
                         dq_dashboard_url: str | None = None,
                         text_inject: str | None = None) -> str:
    """Parent message. Posted once; never edited.

    The leading emoji reflects the aggregate severity at open time:
    critical -> red, warning -> yellow, else green. If `first_fire_row` is
    provided (flat / flat-with-resolve-replies modes) the opener body
    includes the initial fire card so the opener itself is the rich alert.
    In thread mode `counts` carries the frozen-at-open summary so channel
    scanning doesn't require thread expansion.

    `dq_dashboard_url` (optional): added as an extra header line linking to a
    config-specific Data Quality dashboard page. `text_inject` (optional):
    free-form Slack mrkdwn appended as the final line so subscribers (e.g.
    `<@U…>` or `<!subteam^S…>` mentions) ping exactly once per incident.
    Both are gated on truthy-after-strip so configs that don't opt in render
    unchanged.
    """
    emoji = _SEVERITY_EMOJI.get(severity, ":large_green_circle:")
    env_line = f"\n*Environment*: {environment}" if environment != "prod" else ""
    desc = description or "No description available"
    dq = (dq_dashboard_url or "").strip()
    dq_line = f"\n*DQ dashboard*: <{dq}|open>" if dq else ""
    header = (
        f"{emoji} *Incident*: `{config_name}`\n"
        f"*Data date*: `{anomaly_date.isoformat()}`\n"
        f"*Dashboard*: <{looker_url}|Anomaly Detection>"
        f"{dq_line}"
        f"{env_line}\n"
        f"_{desc}_"
    )
    inject = (text_inject or "").strip()
    inject_suffix = f"\n\n{inject}" if inject else ""
    if first_fire_row is not None:
        anomaly_type_lh = first_fire_row.get("anomaly_type_lower_higher") or "normal"
        return (
            f"{header}\n"
            f"*Anomaly*: {anomaly_type_lh}\n"
            f"{_render_fire_body(first_fire_row, looker_url)}"
            f"{inject_suffix}"
        )
    if counts is not None and any(counts.values()):
        total = sum(counts.values())
        return (
            f"{header}\n"
            f"*State* ({total} active):\n"
            f"{_render_counts_table(counts)}"
            f"{inject_suffix}"
        )
    return f"{header}{inject_suffix}"


def render_fire(row: dict, looker_url: str) -> str:
    """Initial fire for a (dim, method)."""
    anomaly_type_lh = row["anomaly_type_lower_higher"]
    emoji = _EMOJI.get(anomaly_type_lh, ":grey_question:")
    return (
        f"{emoji} *New*: {anomaly_type_lh}\n"
        f"{_render_fire_body(row, looker_url)}"
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
    return (
        f":bar_chart: *Summary* ({total} active)\n"
        f"{_render_counts_table(counts)}"
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
