"""Anomaly alerting orchestrator (v2: data-date scoping + append-only).

Queries the deltas table, groups by (config, DATE(timestamp)), decides
per-thread actions via the pure state machine in state.py, and applies
them via bq.py and slack.py.

Thread identity is `(config_name, anomaly_date)`. Each firing dim+method
posts a 'fire' reply; each bucket flip posts a 'severity_change' reply;
each return to normal posts a 'resolve' reply; the aggregate state posts
one debounced 'summary' reply per thread per run. Parent messages are
never edited.
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
    report_id: str,
    page_id: str,
    now: datetime.datetime,
    dry_run: bool = False,
) -> None:
    """Translate state-machine actions into Slack + BigQuery calls.

    Actions reference the "pending" parent via `incident_slack_ts = None`
    when an `OpenThread` action is scheduled earlier in the batch. The
    real ts is patched in after `OpenThread` posts.
    """
    new_parent_ts: str | None = None

    for action in actions:
        if isinstance(action, state.OpenThread):
            # Thread-mode openers carry the initial counts table; flat
            # modes leave counts=None. Persist whatever the state machine
            # decided so the next run's debounce comparison works.
            counts = action.counts or {
                "critical_higher": 0, "critical_lower": 0,
                "warning_higher": 0, "warning_lower": 0,
            }
            # In flat mode the opener embeds a fire-card; point its
            # dashboard link at the first firing (dim, method). Otherwise
            # the header-only opener points at the config overview.
            first_row = action.first_fire_row
            looker_url = slacklib.make_looker_studio_url(
                report_id, page_id, action.config_name,
                (first_row or {}).get("forecast_method") or "",
                (first_row or {}).get("dimension_split_value") or "")
            text = slacklib.render_thread_opener(
                action.config_name, action.anomaly_date, environment,
                action.description, looker_url,
                severity=action.severity,
                first_fire_row=action.first_fire_row,
                counts=action.counts,
                dq_dashboard_url=action.dq_dashboard_url,
                text_inject=action.text_inject)
            logging.info("[open_thread] %s / %s", action.config_name,
                         action.anomaly_date)
            if dry_run:
                new_parent_ts = "DRYRUN-" + str(id(action))
                continue
            ts = slacklib.post_parent(slack_client, action.slack_channel_id, text)
            new_parent_ts = ts
            bq.insert_incident(
                bq_client, incidents_table,
                config_name=action.config_name,
                anomaly_date=action.anomaly_date,
                slack_channel_id=action.slack_channel_id,
                slack_ts=ts, now=now,
                summary_counts_json=json.dumps(counts),
                client_msg_id=bq.new_client_msg_id(),
            )

        elif isinstance(action, state.PostFire):
            parent_ts = _resolve_parent_ts(
                action.incident_slack_ts, new_parent_ts, action.config_name,
                dry_run)
            if parent_ts is None:
                continue
            looker_url = slacklib.make_looker_studio_url(
                report_id, page_id, action.config_name,
                action.forecast_method, action.dimension_split_value)
            text = slacklib.render_fire(action.deltas_row, looker_url)
            logging.info("[post_fire] %s / %s / %s", action.config_name,
                         action.dimension_split_value or "<no-dim>",
                         action.anomaly_type_lower_higher)
            if dry_run:
                continue
            ts = slacklib.post_reply(slack_client, action.slack_channel_id,
                                     parent_ts, text)
            bq.insert_reply_event(
                bq_client, replies_table,
                incident_slack_ts=parent_ts,
                config_name=action.config_name,
                dimension_split_value=action.dimension_split_value or None,
                forecast_method=action.forecast_method or None,
                slack_ts=ts,
                slack_channel_id=action.slack_channel_id,
                kind="fire",
                anomaly_type_lower_higher=action.anomaly_type_lower_higher,
                previous_anomaly_type_lower_higher=None,
                anomaly_timestamp=action.deltas_row.get("timestamp"),
                now=now,
                client_msg_id=bq.new_client_msg_id(),
            )

        elif isinstance(action, state.PostSeverityChange):
            parent_ts = _resolve_parent_ts(
                action.incident_slack_ts, new_parent_ts, action.config_name,
                dry_run)
            if parent_ts is None:
                continue
            looker_url = slacklib.make_looker_studio_url(
                report_id, page_id, action.config_name,
                action.forecast_method, action.dimension_split_value)
            text = slacklib.render_severity_change(
                action.deltas_row,
                action.previous_anomaly_type_lower_higher,
                action.new_anomaly_type_lower_higher,
                looker_url)
            logging.info("[severity_change] %s / %s: %s -> %s",
                         action.config_name,
                         action.dimension_split_value or "<no-dim>",
                         action.previous_anomaly_type_lower_higher,
                         action.new_anomaly_type_lower_higher)
            if dry_run:
                continue
            ts = slacklib.post_reply(slack_client, action.slack_channel_id,
                                     parent_ts, text)
            bq.insert_reply_event(
                bq_client, replies_table,
                incident_slack_ts=parent_ts,
                config_name=action.config_name,
                dimension_split_value=action.dimension_split_value or None,
                forecast_method=action.forecast_method or None,
                slack_ts=ts,
                slack_channel_id=action.slack_channel_id,
                kind="severity_change",
                anomaly_type_lower_higher=action.new_anomaly_type_lower_higher,
                previous_anomaly_type_lower_higher=action.previous_anomaly_type_lower_higher,
                anomaly_timestamp=action.deltas_row.get("timestamp"),
                now=now,
                client_msg_id=bq.new_client_msg_id(),
            )

        elif isinstance(action, state.PostResolve):
            parent_ts = _resolve_parent_ts(
                action.incident_slack_ts, new_parent_ts, action.config_name,
                dry_run)
            if parent_ts is None:
                continue
            text = slacklib.render_resolve(
                action.previous_anomaly_type_lower_higher,
                action.dimension_split_value or None)
            logging.info("[resolve] %s / %s",
                         action.config_name,
                         action.dimension_split_value or "<no-dim>")
            if dry_run:
                continue
            ts = slacklib.post_reply(slack_client, action.slack_channel_id,
                                     parent_ts, text)
            bq.insert_reply_event(
                bq_client, replies_table,
                incident_slack_ts=parent_ts,
                config_name=action.config_name,
                dimension_split_value=action.dimension_split_value or None,
                forecast_method=action.forecast_method or None,
                slack_ts=ts,
                slack_channel_id=action.slack_channel_id,
                kind="resolve",
                anomaly_type_lower_higher="normal",
                previous_anomaly_type_lower_higher=action.previous_anomaly_type_lower_higher,
                anomaly_timestamp=None,
                now=now,
                client_msg_id=bq.new_client_msg_id(),
            )

        elif isinstance(action, state.PostSummary):
            parent_ts = _resolve_parent_ts(
                action.incident_slack_ts, new_parent_ts, action.config_name,
                dry_run)
            if parent_ts is None:
                continue
            text = slacklib.render_summary(action.counts)
            logging.info("[summary] %s / %s counts=%s",
                         action.config_name, action.anomaly_date, action.counts)
            if dry_run:
                continue
            ts = slacklib.post_reply(slack_client, action.slack_channel_id,
                                     parent_ts, text)
            bq.insert_reply_event(
                bq_client, replies_table,
                incident_slack_ts=parent_ts,
                config_name=action.config_name,
                dimension_split_value=None,
                forecast_method=None,
                slack_ts=ts,
                slack_channel_id=action.slack_channel_id,
                kind="summary",
                anomaly_type_lower_higher=None,
                previous_anomaly_type_lower_higher=None,
                anomaly_timestamp=None,
                now=now,
                client_msg_id=bq.new_client_msg_id(),
            )
            # Update the debounce key on the incident row so the next run
            # doesn't re-post the same summary.
            bq.update_incident(bq_client, incidents_table,
                               slack_ts=parent_ts, now=now,
                               summary_counts_json=json.dumps(action.counts))

        elif isinstance(action, state.CloseThread):
            logging.info("[close_thread] %s / %s reason=%s",
                         action.config_name, action.anomaly_date, action.reason)
            if dry_run:
                continue
            text = slacklib.render_closed(action.reason)
            slacklib.post_reply(slack_client, action.slack_channel_id,
                                action.incident_slack_ts, text)
            bq.update_incident(bq_client, incidents_table,
                               slack_ts=action.incident_slack_ts, now=now,
                               status="resolved", closed_at=now)


def _count_firing_buckets(rows: list[dict]) -> dict:
    """Counts of non-normal anomaly buckets across deltas rows. Used only for
    forensics on bootstrap rows (so a future analyst can see what was
    suppressed); no behavioural impact."""
    out = {"critical_higher": 0, "critical_lower": 0,
           "warning_higher": 0, "warning_lower": 0}
    for r in rows:
        t = r.get("anomaly_type_lower_higher")
        if t in out:
            out[t] += 1
    return out


def _resolve_parent_ts(
    action_ts: str | None,
    new_parent_ts: str | None,
    config_name: str,
    dry_run: bool,
) -> str | None:
    """Pick the right parent slack_ts: explicit ts on the action, or the
    ts from an OpenThread applied earlier in this batch. Returns None
    (with a log) if neither is available -- the orchestrator should skip
    the action in that case."""
    if action_ts is not None:
        return action_ts
    if new_parent_ts is not None:
        return new_parent_ts
    if dry_run:
        return "DRYRUN-missing"
    logging.error("[orphan] no parent ts resolvable for %s", config_name)
    return None


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
        for r in deltas_all:
            if isinstance(r.get("timestamp"), str):
                r["timestamp"] = datetime.datetime.fromisoformat(r["timestamp"])
            if "anomaly_date" not in r and isinstance(r.get("timestamp"), datetime.datetime):
                r["anomaly_date"] = r["timestamp"].date()
        bootstrapped_pairs: set[tuple[str, datetime.date]] = set()
        seen_configs: set[str] = set()
    else:
        deltas_all = bq.query_deltas_with_open_incidents(
            bq_client, environment, incidents_table)
        # Bootstrap state from previous runs.
        bootstrapped_pairs = bq.list_bootstrapped_pairs(bq_client, incidents_table)
        seen_configs = bq.list_configs_with_any_incident(bq_client, incidents_table)

    # Group deltas by (config_name, anomaly_date), dropping pairs that were
    # bootstrapped on a previous run -- those are silenced for good.
    by_thread: dict[tuple[str, datetime.date], list[dict]] = {}
    for r in deltas_all:
        d = r.get("anomaly_date")
        if isinstance(d, str):
            d = datetime.date.fromisoformat(d)
        if not isinstance(d, datetime.date):
            logging.warning("[skip] row missing anomaly_date: %s", r.get("config_name"))
            continue
        key: tuple[str, datetime.date] = (r["config_name"], d)
        if key in bootstrapped_pairs:
            continue
        by_thread.setdefault(key, []).append(r)

    # First-seen configs: every (config, anomaly_date) pair with anomaly_date
    # before today is silently bootstrapped, so the wave of historical
    # anomalies that lands when a new dataloader config first runs doesn't
    # spam Slack. Today's anomalies still flow through normally so a
    # genuinely new config can still alert on day one.
    today = now.date()
    fresh_configs = {cn for (cn, _) in by_thread} - seen_configs
    if fresh_configs:
        logging.info("[bootstrap] first-seen config(s): %s", sorted(fresh_configs))
    bootstrapped_now: list[tuple[str, datetime.date]] = []
    for key in list(by_thread.keys()):
        cn, d = key
        if cn not in fresh_configs or d >= today:
            continue
        bootstrapped_now.append(key)
        if not dry_run and not replay_fixture:
            counts = _count_firing_buckets(by_thread[key])
            bq.insert_bootstrap_incident(
                bq_client, incidents_table,
                config_name=cn,
                anomaly_date=d,
                summary_counts_json=json.dumps(counts),
                now=now,
            )
        del by_thread[key]
    if bootstrapped_now:
        logging.info("[bootstrap] suppressed %d historical (config, date) pair(s)",
                     len(bootstrapped_now))

    # Also visit (config, date) tuples that have an open incident but no
    # fresh deltas -- so resolution detection runs.
    thread_keys = set(by_thread.keys())
    if not replay_fixture:
        try:
            thread_keys.update(bq.list_open_incident_keys(bq_client, incidents_table))
        except Exception as e:
            logging.warning("list_open_incident_keys failed: %s", e)

    for (config_name, anomaly_date) in sorted(thread_keys, key=lambda x: (x[0], str(x[1]))):
        rows = by_thread.get((config_name, anomaly_date), [])
        # Per-config metadata, joined onto every deltas row from the
        # config_descriptions_<env> seed. None when iterating an open incident
        # with no fresh deltas (matches the existing `description` fallback).
        first_row = rows[0] if rows else {}
        description = first_row.get("description") or None
        dq_dashboard_url = first_row.get("dq_dashboard_url") or None
        text_inject = first_row.get("text_inject") or None

        channel = bq.get_channel_config(bq_client, config_name, environment)
        open_incident = bq.find_open_incident(
            bq_client, incidents_table, config_name, anomaly_date)

        # Duplicate-thread guard: `find_open_incident` may return a
        # recently-resolved incident (closed within the last 24h). Flip
        # its row back to 'open' so subsequent replies append to the same
        # Slack thread instead of opening a duplicate one.
        has_fresh_anomaly = any(
            r.get("anomaly_type_lower_higher") and
            r["anomaly_type_lower_higher"] != "normal"
            for r in rows
        )
        if (open_incident is not None
                and open_incident.get("status") == "resolved"
                and has_fresh_anomaly):
            logging.info("[reopen] %s / %s within 24h",
                         config_name, anomaly_date)
            if not dry_run:
                bq.update_incident(
                    bq_client, incidents_table,
                    slack_ts=open_incident["slack_ts"], now=now,
                    status="open", clear_closed_at=True)
            # Reflect the flip in the in-memory dict so the state machine
            # treats it as open.
            open_incident = {**open_incident, "status": "open",
                             "closed_at": None}
        elif (open_incident is not None
                and open_incident.get("status") == "resolved"):
            # Recently-resolved but nothing new to announce; leave it closed.
            open_incident = None

        reply_events = (
            bq.find_reply_events(bq_client, replies_table,
                                 open_incident["slack_ts"])
            if open_incident else []
        )

        actions = state.process_thread(
            config_name=config_name,
            anomaly_date=anomaly_date,
            slack_channel_id=channel["slack_channel_id"],
            deltas_rows=rows,
            open_incident=open_incident,
            reply_events=reply_events,
            now=now,
            description=description,
            dq_dashboard_url=dq_dashboard_url,
            text_inject=text_inject,
        )

        if actions:
            logging.info("[%s / %s] %d actions: %s", config_name, anomaly_date,
                         len(actions), [type(a).__name__ for a in actions])
            apply_actions(
                actions,
                bq_client=bq_client, slack_client=slack_client,
                incidents_table=incidents_table, replies_table=replies_table,
                environment=environment,
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
    # Legacy no-op arg for backward compatibility with scheduler body.
    parser.add_argument("--deduplication-index", required=False)

    args, _ = parser.parse_known_args()

    environment = bq.canonical_environment(args.environment)
    incidents = bq.canonical_table_id(
        args.incidents_table or _derive_default_table(environment, "incidents"))
    replies = bq.canonical_table_id(
        args.replies_table or _derive_default_table(environment, "incident_replies"))

    run(
        environment=environment,
        incidents_table=incidents,
        replies_table=replies,
        report_id=args.report_id,
        page_id=args.page_id,
        dry_run=args.dry_run,
        replay_fixture=args.replay,
    )
