"""Anomaly alerting orchestrator.

Queries the deltas table, groups by config, decides per-config actions via
the pure state machine in state.py, and applies them via bq.py and slack.py.

One Slack "incident" == one top-level parent message per (config, open
period). All per-dimension alerts for that incident are flat thread
replies under the parent. Classifications changes edit the reply in
place; resolution edits the reply to mark it resolved; parent summary
(critical/warning x lower/higher counts) is edited in place as counts
change. Incidents auto-close after `thread_timeout_hours` of inactivity
(default 24h) and are hard-capped at 7 days.
"""

from __future__ import annotations

import argparse
import datetime
import json
import logging
import os

from google.cloud import bigquery
from slack_sdk import WebClient

import bq
import slack as slacklib
import state


def apply_actions(
    actions: list,
    *,
    bq_client: bigquery.Client,
    slack_client: WebClient,
    incidents_table: str,
    replies_table: str,
    environment: str,
    config_name: str,
    description: str | None,
    report_id: str,
    page_id: str,
    now: datetime.datetime,
    dry_run: bool = False,
) -> None:
    """Translate state-machine actions into Slack + BigQuery calls.

    Actions reference the "pending" parent via `incident_slack_ts = None`
    when an OpenIncident action is scheduled earlier in the batch. The
    real ts is patched in here after OpenIncident is applied.
    """
    new_parent_ts: str | None = None

    for action in actions:
        if isinstance(action, state.OpenIncident):
            counts = {"critical_higher": 0, "critical_lower": 0,
                      "warning_higher": 0, "warning_lower": 0}
            looker_url = slacklib.make_looker_studio_url(
                report_id, page_id, action.config_name, "", "")
            text = slacklib.render_summary(
                environment, action.config_name, description, counts, looker_url)
            logging.info("[open_incident] %s -> %s", action.config_name,
                         action.slack_channel_id)
            if dry_run:
                new_parent_ts = "DRYRUN-" + str(id(action))
                continue
            ts = slacklib.post_parent(slack_client, action.slack_channel_id, text)
            new_parent_ts = ts
            bq.insert_incident(
                bq_client, incidents_table,
                config_name=action.config_name,
                slack_channel_id=action.slack_channel_id,
                slack_ts=ts, now=now,
                summary_counts_json=json.dumps(counts),
                client_msg_id=bq.new_client_msg_id(),
            )

        elif isinstance(action, state.CreateReply):
            parent_ts = new_parent_ts
            if parent_ts is None:
                # No OpenIncident in this batch: fetch from DB.
                existing = bq.find_open_incident(bq_client, incidents_table,
                                                 action.config_name)
                if existing is None:
                    logging.error(
                        "[create_reply] no open incident for %s; skipping",
                        action.config_name)
                    continue
                parent_ts = existing["slack_ts"]

            looker_url = slacklib.make_looker_studio_url(
                report_id, page_id, action.config_name,
                action.forecast_method, action.dimension_split_value)
            text = slacklib.render_dimension_card(action.deltas_row, looker_url)
            logging.info("[create_reply] %s / %s / %s", action.config_name,
                         action.dimension_split_value, action.anomaly_type_lower_higher)
            if dry_run:
                continue
            ts = slacklib.post_reply(slack_client, action.slack_channel_id,
                                     parent_ts, text)
            bq.insert_reply(
                bq_client, replies_table,
                incident_slack_ts=parent_ts,
                config_name=action.config_name,
                dimension_split_value=action.dimension_split_value,
                forecast_method=action.forecast_method,
                slack_ts=ts,
                slack_channel_id=action.slack_channel_id,
                anomaly_type_lower_higher=action.anomaly_type_lower_higher,
                last_anomaly_timestamp=action.deltas_row["timestamp"],
                now=now,
                client_msg_id=bq.new_client_msg_id(),
            )

        elif isinstance(action, state.UpdateReplyClassification):
            looker_url = slacklib.make_looker_studio_url(
                report_id, page_id, config_name,
                action.deltas_row.get("forecast_method", ""),
                action.dimension_split_value)
            text = slacklib.render_dimension_card(action.deltas_row, looker_url)
            logging.info("[update_reply] %s / %s -> %s",
                         config_name, action.dimension_split_value,
                         action.new_anomaly_type_lower_higher)
            if dry_run:
                continue
            ok = slacklib.update_message(slack_client, action.slack_channel_id,
                                         action.reply_slack_ts, text)
            if ok:
                bq.update_reply(
                    bq_client, replies_table, slack_ts=action.reply_slack_ts,
                    now=now,
                    anomaly_type_lower_higher=action.new_anomaly_type_lower_higher,
                    last_anomaly_timestamp=action.deltas_row["timestamp"],
                )

        elif isinstance(action, state.ResolveReply):
            # Fetch the current text so we can keep the original content
            # and prepend the resolved marker. Slack doesn't return the
            # previous text directly; we re-render a placeholder.
            text = (":large_green_circle: *Resolved* (was "
                    + action.previous_anomaly_type_lower_higher + ")\n"
                    f"*Dimension*: {action.dimension_split_value}")
            logging.info("[resolve_reply] %s / %s",
                         config_name, action.dimension_split_value)
            if dry_run:
                continue
            ok = slacklib.update_message(slack_client, action.slack_channel_id,
                                         action.reply_slack_ts, text)
            if ok:
                bq.update_reply(bq_client, replies_table,
                                slack_ts=action.reply_slack_ts, now=now,
                                status="resolved",
                                anomaly_type_lower_higher="normal")

        elif isinstance(action, state.UpdateParentSummary):
            parent_ts = action.incident_slack_ts or new_parent_ts
            if parent_ts is None:
                logging.warning("[update_parent] no parent ts; skipping")
                continue
            looker_url = slacklib.make_looker_studio_url(
                report_id, page_id, action.config_name, "", "")
            text = slacklib.render_summary(
                environment, action.config_name, description,
                action.counts, looker_url)
            logging.info("[update_parent] %s counts=%s",
                         action.config_name, action.counts)
            if dry_run:
                continue
            ok = slacklib.update_message(slack_client, action.slack_channel_id,
                                         parent_ts, text)
            if ok:
                bq.update_incident(bq_client, incidents_table, slack_ts=parent_ts,
                                   now=now,
                                   summary_counts_json=json.dumps(action.counts))

        elif isinstance(action, state.CloseIncident):
            # Append a closed marker; callers to `update_message` that fail
            # softly (message deleted) are fine -- we still mark BQ closed.
            text = (":white_check_mark: *Incident closed* (" + action.reason
                    + ")\n*Config*: " + action.config_name)
            logging.info("[close_incident] %s reason=%s",
                         action.config_name, action.reason)
            if dry_run:
                continue
            slacklib.update_message(slack_client, action.slack_channel_id,
                                    action.incident_slack_ts, text)
            bq.update_incident(bq_client, incidents_table,
                               slack_ts=action.incident_slack_ts, now=now,
                               status="resolved", closed_at=now)


def run(
    *,
    environment: str,
    incidents_table: str,
    replies_table: str,
    report_id: str,
    page_id: str,
    dry_run: bool = False,
    replay_fixture: str | None = None,
) -> None:
    bq_client = bigquery.Client()
    slack_client = WebClient(token=os.getenv("SLACK_BOT_TOKEN"))
    now = datetime.datetime.now(datetime.timezone.utc)

    if replay_fixture:
        with open(replay_fixture) as fh:
            deltas_all = json.load(fh)
        # Normalize timestamps from ISO strings back to datetime.
        for r in deltas_all:
            if isinstance(r.get("timestamp"), str):
                r["timestamp"] = datetime.datetime.fromisoformat(r["timestamp"])
    else:
        deltas_all = bq.query_deltas_with_open_replies(
            bq_client, environment, replies_table)

    # Group by config, also ensure we visit configs with open incidents
    # that have no active deltas rows (so we can close them on timeout).
    deltas_by_config: dict[str, list[dict]] = {}
    for r in deltas_all:
        deltas_by_config.setdefault(r["config_name"], []).append(r)

    active_configs = set(deltas_by_config.keys())
    if not replay_fixture:
        try:
            active_configs.update(
                bq.list_configs_with_activity(bq_client, environment,
                                              incidents_table))
        except Exception as e:
            logging.warning("list_configs_with_activity failed: %s", e)

    for config_name in sorted(active_configs):
        rows = deltas_by_config.get(config_name, [])
        description = rows[0].get("description") if rows else None

        channel = bq.get_channel_config(bq_client, config_name, environment)
        open_incident = bq.find_open_incident(bq_client, incidents_table,
                                              config_name)
        open_replies = bq.find_open_replies(bq_client, replies_table,
                                            config_name) \
            if open_incident else []

        actions = state.process_config(
            config_name=config_name,
            slack_channel_id=channel["slack_channel_id"],
            thread_timeout_hours=channel.get("thread_timeout_hours") or state.DEFAULT_TIMEOUT_HOURS,
            deltas_rows=rows,
            open_incident=open_incident,
            open_replies=open_replies,
            now=now,
        )

        if actions:
            logging.info("[%s] %d actions: %s", config_name, len(actions),
                         [type(a).__name__ for a in actions])
            apply_actions(
                actions,
                bq_client=bq_client, slack_client=slack_client,
                incidents_table=incidents_table, replies_table=replies_table,
                environment=environment, config_name=config_name,
                description=description,
                report_id=report_id, page_id=page_id, now=now,
                dry_run=dry_run,
            )


def _derive_default_table(env: str, suffix: str) -> str:
    return (f"world-fishing-827.tech_anomaly_detection."
            f"t_qa_gfw_anomaly_detection_alerting_{env}_{suffix}")


if __name__ == "__main__":
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO").upper())

    parser = argparse.ArgumentParser()
    parser.add_argument("--environment", default="dev")
    parser.add_argument("--incidents-table",
                        help="Default: derived from environment.")
    parser.add_argument("--replies-table",
                        help="Default: derived from environment.")
    parser.add_argument("--looker-report-id",
                        default="1f9b8d37-a87b-4177-a108-3b3e87ce5804",
                        dest="report_id")
    parser.add_argument("--looker-page-id", default="p_ufk1l0slhd",
                        dest="page_id")
    parser.add_argument("--dry-run", action="store_true",
                        help="Log actions without calling Slack or BQ writes.")
    parser.add_argument("--replay",
                        help="Path to a JSON fixture of deltas rows for replay.")
    # Accept the legacy --deduplication-index arg but ignore it (kept for
    # backward compatibility with the scheduler body until Terraform rolls).
    parser.add_argument("--deduplication-index", required=False)

    args, _ = parser.parse_known_args()

    incidents = args.incidents_table or _derive_default_table(
        args.environment, "incidents")
    replies = args.replies_table or _derive_default_table(
        args.environment, "incident_replies")

    run(
        environment=args.environment,
        incidents_table=incidents,
        replies_table=replies,
        report_id=args.report_id,
        page_id=args.page_id,
        dry_run=args.dry_run,
        replay_fixture=args.replay,
    )
