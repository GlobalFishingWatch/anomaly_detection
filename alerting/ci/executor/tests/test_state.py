"""Unit tests for the v2 threaded-alerting state machine."""

from __future__ import annotations

import datetime
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import state  # noqa: E402


NOW = datetime.datetime(2026, 4, 22, 12, 0, tzinfo=datetime.timezone.utc)
DATE = datetime.date(2026, 4, 22)


def _row(config="c1", dim="d1", method="mstl",
         anomaly_type_lower_higher="critical_higher",
         timestamp=None):
    ts = timestamp or datetime.datetime(2026, 4, 22, 0, 0,
                                         tzinfo=datetime.timezone.utc)
    return {
        "config_name": config,
        "dimension_split_value": dim,
        "forecast_method": method,
        "anomaly_type_lower_higher": anomaly_type_lower_higher,
        "timestamp": ts,
        "forecast_value": 1.0,
        "actual_value": 2.5,
        "delta_rel": 1.5,
        "exceeded_threshold_lower_higher": 1.0,
        "source_sql": "",
        "description": "test",
    }


def _incident(slack_ts="t-parent", anomaly_date=DATE, opened_at=None,
              summary_counts_json=None):
    return {
        "config_name": "c1",
        "anomaly_date": anomaly_date,
        "slack_channel_id": "C1",
        "slack_ts": slack_ts,
        "opened_at": opened_at or NOW - datetime.timedelta(hours=1),
        "status": "open",
        "summary_counts_json": summary_counts_json,
    }


def _event(kind, dim="d1", method="mstl",
           anomaly_type_lower_higher: str | None = "critical_higher",
           previous_type=None, posted_at=None, slack_ts=None):
    return {
        "incident_slack_ts": "t-parent",
        "config_name": "c1",
        "dimension_split_value": dim,
        "forecast_method": method,
        "slack_ts": slack_ts or f"t-ev-{kind}",
        "slack_channel_id": "C1",
        "kind": kind,
        "anomaly_type_lower_higher": anomaly_type_lower_higher,
        "previous_anomaly_type_lower_higher": previous_type,
        "posted_at": posted_at or NOW - datetime.timedelta(minutes=30),
    }


def _types(actions):
    return [type(a).__name__ for a in actions]


# --- scenarios --------------------------------------------------------

def test_first_fire_opens_thread_and_posts_fire_and_summary():
    actions = state.process_thread(
        config_name="c1", anomaly_date=DATE, slack_channel_id="C1",
        deltas_rows=[_row()], open_incident=None, reply_events=[], now=NOW,
    )
    types = _types(actions)
    assert "OpenThread" in types
    assert "PostFire" in types
    assert "PostSummary" in types
    # The summary counts should reflect the new fire, not be zero.
    summary = next(a for a in actions if type(a).__name__ == "PostSummary")
    assert summary.counts["critical_higher"] == 1


def test_same_bucket_refire_is_noop():
    incident = _incident(
        summary_counts_json=json.dumps({"critical_higher": 1, "critical_lower": 0,
                                         "warning_higher": 0, "warning_lower": 0}),
    )
    events = [_event("fire", anomaly_type_lower_higher="critical_higher"),
              _event("summary", anomaly_type_lower_higher=None)]
    actions = state.process_thread(
        config_name="c1", anomaly_date=DATE, slack_channel_id="C1",
        deltas_rows=[_row()], open_incident=incident,
        reply_events=events, now=NOW,
    )
    assert _types(actions) == []


def test_severity_change_posts_new_reply():
    incident = _incident(
        summary_counts_json=json.dumps({"warning_higher": 1, "critical_higher": 0,
                                         "critical_lower": 0, "warning_lower": 0}),
    )
    events = [_event("fire", anomaly_type_lower_higher="warning_higher")]
    new_row = _row(anomaly_type_lower_higher="critical_higher")
    actions = state.process_thread(
        config_name="c1", anomaly_date=DATE, slack_channel_id="C1",
        deltas_rows=[new_row], open_incident=incident,
        reply_events=events, now=NOW,
    )
    types = _types(actions)
    assert "PostSeverityChange" in types
    assert "PostSummary" in types
    summary = next(a for a in actions if type(a).__name__ == "PostSummary")
    assert summary.counts["critical_higher"] == 1
    assert summary.counts["warning_higher"] == 0


def test_resolution_posts_resolve_and_closes():
    incident = _incident(
        summary_counts_json=json.dumps({"critical_higher": 1, "critical_lower": 0,
                                         "warning_higher": 0, "warning_lower": 0}),
    )
    events = [_event("fire", anomaly_type_lower_higher="critical_higher")]
    resolved_row = _row(anomaly_type_lower_higher="normal",
                        timestamp=NOW - datetime.timedelta(hours=2))
    actions = state.process_thread(
        config_name="c1", anomaly_date=DATE, slack_channel_id="C1",
        deltas_rows=[resolved_row], open_incident=incident,
        reply_events=events, now=NOW,
    )
    types = _types(actions)
    assert "PostResolve" in types
    assert "PostSummary" in types
    assert "CloseThread" in types


def test_second_run_after_resolve_is_fully_quiet():
    """Once a dim is resolved and summary posted, a follow-up run where
    nothing changed should emit NO actions."""
    incident = _incident(
        summary_counts_json=json.dumps({"critical_higher": 0, "critical_lower": 0,
                                         "warning_higher": 0, "warning_lower": 0}),
    )
    # Event log: fire, then resolve.
    events = [
        _event("fire", anomaly_type_lower_higher="critical_higher",
               posted_at=NOW - datetime.timedelta(hours=2)),
        _event("resolve", anomaly_type_lower_higher="normal",
               previous_type="critical_higher",
               posted_at=NOW - datetime.timedelta(hours=1)),
    ]
    normal_row = _row(anomaly_type_lower_higher="normal",
                      timestamp=NOW - datetime.timedelta(hours=2))
    actions = state.process_thread(
        config_name="c1", anomaly_date=DATE, slack_channel_id="C1",
        deltas_rows=[normal_row], open_incident=incident,
        reply_events=events, now=NOW,
    )
    # No new transitions; no summary change; nothing to post.
    t = _types(actions)
    assert "PostResolve" not in t
    assert "PostSeverityChange" not in t
    assert "PostFire" not in t
    assert "PostSummary" not in t


def test_multiple_dimensions_same_thread_one_summary():
    rows = [
        _row(dim="d1"),
        _row(dim="d2"),
        _row(dim="d3", anomaly_type_lower_higher="warning_higher"),
    ]
    actions = state.process_thread(
        config_name="c1", anomaly_date=DATE, slack_channel_id="C1",
        deltas_rows=rows, open_incident=None, reply_events=[], now=NOW,
    )
    types = _types(actions)
    assert types.count("OpenThread") == 1
    assert types.count("PostFire") == 3
    assert types.count("PostSummary") == 1
    summary = next(a for a in actions if type(a).__name__ == "PostSummary")
    assert summary.counts["critical_higher"] == 2
    assert summary.counts["warning_higher"] == 1


def test_no_zero_state_summary_on_open():
    """On thread open, the summary must carry the real counts, not zeros.
    This prevents the v1 green-then-red flash pattern."""
    actions = state.process_thread(
        config_name="c1", anomaly_date=DATE, slack_channel_id="C1",
        deltas_rows=[_row()], open_incident=None, reply_events=[], now=NOW,
    )
    # Exactly one PostSummary, and it must be non-zero.
    summaries = [a for a in actions if type(a).__name__ == "PostSummary"]
    assert len(summaries) == 1
    assert sum(summaries[0].counts.values()) > 0


def test_empty_state_emits_nothing():
    actions = state.process_thread(
        config_name="c1", anomaly_date=DATE, slack_channel_id="C1",
        deltas_rows=[], open_incident=None, reply_events=[], now=NOW,
    )
    assert actions == []


def test_hard_cap_closes_regardless_of_state():
    ancient = _incident(opened_at=NOW - datetime.timedelta(days=8))
    events = [_event("fire", anomaly_type_lower_higher="critical_higher")]
    actions = state.process_thread(
        config_name="c1", anomaly_date=DATE, slack_channel_id="C1",
        deltas_rows=[_row()], open_incident=ancient,
        reply_events=events, now=NOW,
    )
    # Hard cap is an immediate short-circuit: only CloseThread.
    types = _types(actions)
    assert types == ["CloseThread"]
    close = actions[0]
    assert close.reason == "hard_cap"


def test_value_change_same_bucket_is_noop():
    """Pure value change with same classification should not emit any
    action (preserves the fuzzy-dedup value-invariance)."""
    incident = _incident(
        summary_counts_json=json.dumps({"critical_higher": 1, "critical_lower": 0,
                                         "warning_higher": 0, "warning_lower": 0}),
    )
    events = [_event("fire", anomaly_type_lower_higher="critical_higher")]
    # Same bucket, different delta_rel.
    row = _row(anomaly_type_lower_higher="critical_higher")
    row["delta_rel"] = 99.0  # changed from the default
    actions = state.process_thread(
        config_name="c1", anomaly_date=DATE, slack_channel_id="C1",
        deltas_rows=[row], open_incident=incident,
        reply_events=events, now=NOW,
    )
    assert _types(actions) == []


def test_latest_timestamp_wins_for_duplicate_keys():
    older = _row(anomaly_type_lower_higher="critical_higher",
                 timestamp=NOW - datetime.timedelta(days=3))
    newer = _row(anomaly_type_lower_higher="normal",
                 timestamp=NOW - datetime.timedelta(hours=2))
    incident = _incident(
        summary_counts_json=json.dumps({"critical_higher": 1, "critical_lower": 0,
                                         "warning_higher": 0, "warning_lower": 0}),
    )
    events = [_event("fire", anomaly_type_lower_higher="critical_higher")]
    actions = state.process_thread(
        config_name="c1", anomaly_date=DATE, slack_channel_id="C1",
        deltas_rows=[older, newer], open_incident=incident,
        reply_events=events, now=NOW,
    )
    types = _types(actions)
    assert "PostResolve" in types
    assert "PostSeverityChange" not in types


def test_second_dimension_fires_in_existing_thread():
    """A thread that already has d1 as open; d2 starts firing.
    Expect: PostFire for d2, PostSummary reflecting both."""
    incident = _incident(
        summary_counts_json=json.dumps({"critical_higher": 1, "critical_lower": 0,
                                         "warning_higher": 0, "warning_lower": 0}),
    )
    events = [_event("fire", dim="d1",
                     anomaly_type_lower_higher="critical_higher")]
    rows = [
        _row(dim="d1", anomaly_type_lower_higher="critical_higher"),
        _row(dim="d2", anomaly_type_lower_higher="warning_higher"),
    ]
    actions = state.process_thread(
        config_name="c1", anomaly_date=DATE, slack_channel_id="C1",
        deltas_rows=rows, open_incident=incident,
        reply_events=events, now=NOW,
    )
    types = _types(actions)
    assert types.count("PostFire") == 1   # only d2
    assert "PostSummary" in types
    summary = next(a for a in actions if type(a).__name__ == "PostSummary")
    assert summary.counts["critical_higher"] == 1
    assert summary.counts["warning_higher"] == 1


def test_summary_debounce_suppresses_when_counts_unchanged():
    """If the counts end up identical to the last posted summary, no
    PostSummary is emitted even if a transition occurred."""
    # Start: 1 critical_higher. After: 1 critical_higher (different dim).
    incident = _incident(
        summary_counts_json=json.dumps({"critical_higher": 1, "critical_lower": 0,
                                         "warning_higher": 0, "warning_lower": 0}),
    )
    # d1 resolves; d2 fires critical_higher. Net: still 1 critical_higher.
    events = [_event("fire", dim="d1",
                     anomaly_type_lower_higher="critical_higher")]
    rows = [
        _row(dim="d1", anomaly_type_lower_higher="normal",
             timestamp=NOW - datetime.timedelta(hours=2)),
        _row(dim="d2", anomaly_type_lower_higher="critical_higher"),
    ]
    actions = state.process_thread(
        config_name="c1", anomaly_date=DATE, slack_channel_id="C1",
        deltas_rows=rows, open_incident=incident,
        reply_events=events, now=NOW,
    )
    types = _types(actions)
    assert "PostResolve" in types
    assert "PostFire" in types
    # Counts unchanged (1 -> 1) so no summary.
    assert "PostSummary" not in types
