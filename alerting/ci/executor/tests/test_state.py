"""Unit tests for the threaded-alerting state machine."""

from __future__ import annotations

import datetime
import json
import sys
from pathlib import Path

# Make the executor dir importable regardless of pytest rootdir.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import state  # noqa: E402


NOW = datetime.datetime(2026, 4, 22, 12, 0, tzinfo=datetime.timezone.utc)


def _row(config="c1", dim="d1", method="mstl", anomaly_type_lower_higher="critical_higher",
         timestamp=None):
    return {
        "config_name": config,
        "dimension_split_value": dim,
        "forecast_method": method,
        "anomaly_type_lower_higher": anomaly_type_lower_higher,
        "timestamp": timestamp or datetime.datetime(2026, 4, 22, 0, 0,
                                                     tzinfo=datetime.timezone.utc),
        "forecast_value": 1.0,
        "actual_value": 2.5,
        "delta_rel": 1.5,
        "exceeded_threshold_lower_higher": 1.0,
        "source_sql": "",
        "description": "test",
    }


def _reply(dim="d1", method="mstl", anomaly_type_lower_higher="critical_higher",
           slack_ts="t-reply", slack_channel_id="C1"):
    return {
        "config_name": "c1",
        "dimension_split_value": dim,
        "forecast_method": method,
        "slack_ts": slack_ts,
        "slack_channel_id": slack_channel_id,
        "anomaly_type_lower_higher": anomaly_type_lower_higher,
        "status": "open",
        "last_anomaly_timestamp": datetime.datetime(2026, 4, 22, 0, 0,
                                                     tzinfo=datetime.timezone.utc),
    }


def _incident(slack_ts="t-parent", opened_at=None, last_activity_at=None,
              summary_counts_json=None):
    return {
        "config_name": "c1",
        "slack_channel_id": "C1",
        "slack_ts": slack_ts,
        "opened_at": opened_at or NOW - datetime.timedelta(hours=1),
        "last_activity_at": last_activity_at or NOW - datetime.timedelta(hours=1),
        "status": "open",
        "summary_counts_json": summary_counts_json,
    }


# --- scenarios --------------------------------------------------------

def test_first_fire_opens_incident_and_creates_reply():
    actions = state.process_config(
        config_name="c1", slack_channel_id="C1", thread_timeout_hours=24,
        deltas_rows=[_row()], open_incident=None, open_replies=[], now=NOW,
    )
    types = [type(a).__name__ for a in actions]
    assert "OpenIncident" in types
    assert "CreateReply" in types
    assert "UpdateParentSummary" in types


def test_second_fire_same_dim_type_is_noop():
    # Existing reply at critical_higher, new row also critical_higher.
    actions = state.process_config(
        config_name="c1", slack_channel_id="C1", thread_timeout_hours=24,
        deltas_rows=[_row()],
        open_incident=_incident(
            summary_counts_json=json.dumps({
                "critical_higher": 1, "critical_lower": 0,
                "warning_higher": 0, "warning_lower": 0,
            })),
        open_replies=[_reply()], now=NOW,
    )
    types = [type(a).__name__ for a in actions]
    assert "CreateReply" not in types
    assert "UpdateReplyClassification" not in types
    assert "UpdateParentSummary" not in types


def test_classification_change_triggers_update():
    # Existing reply at warning_higher, new row is critical_higher.
    existing = _reply(anomaly_type_lower_higher="warning_higher")
    new_row = _row(anomaly_type_lower_higher="critical_higher")
    actions = state.process_config(
        config_name="c1", slack_channel_id="C1", thread_timeout_hours=24,
        deltas_rows=[new_row],
        open_incident=_incident(
            summary_counts_json=json.dumps({"warning_higher": 1})),
        open_replies=[existing], now=NOW,
    )
    types = [type(a).__name__ for a in actions]
    assert "UpdateReplyClassification" in types
    assert "UpdateParentSummary" in types


def test_resolution_generates_resolve_and_close():
    # Existing reply open; new delta row is 'normal' for same (dim, method).
    existing = _reply(anomaly_type_lower_higher="critical_higher")
    resolved_row = _row(anomaly_type_lower_higher="normal",
                        timestamp=NOW - datetime.timedelta(hours=2))
    actions = state.process_config(
        config_name="c1", slack_channel_id="C1", thread_timeout_hours=24,
        deltas_rows=[resolved_row],
        open_incident=_incident(),
        open_replies=[existing], now=NOW,
    )
    types = [type(a).__name__ for a in actions]
    assert "ResolveReply" in types
    assert "CloseIncident" in types


def test_timeout_closes_idle_incident():
    # Incident with no recent activity > timeout hours.
    stale = _incident(
        opened_at=NOW - datetime.timedelta(hours=30),
        last_activity_at=NOW - datetime.timedelta(hours=26),
    )
    actions = state.process_config(
        config_name="c1", slack_channel_id="C1", thread_timeout_hours=24,
        deltas_rows=[],  # no activity
        open_incident=stale,
        open_replies=[], now=NOW,
    )
    types = [type(a).__name__ for a in actions]
    assert "CloseIncident" in types
    # The close reason should be timeout
    close = next(a for a in actions if type(a).__name__ == "CloseIncident")
    assert close.reason == "timeout"


def test_hard_cap_closes_even_if_active():
    # Incident older than 7 days regardless of activity.
    ancient = _incident(
        opened_at=NOW - datetime.timedelta(days=8),
        last_activity_at=NOW - datetime.timedelta(hours=1),
    )
    actions = state.process_config(
        config_name="c1", slack_channel_id="C1", thread_timeout_hours=24,
        deltas_rows=[_row()],
        open_incident=ancient,
        open_replies=[_reply()], now=NOW,
    )
    types = [type(a).__name__ for a in actions]
    assert "CloseIncident" in types
    close = next(a for a in actions if type(a).__name__ == "CloseIncident")
    assert close.reason == "hard_cap"


def test_multiple_dimensions_single_incident():
    # Three different dimensions all firing -> one OpenIncident, three CreateReply.
    rows = [
        _row(dim="d1"),
        _row(dim="d2"),
        _row(dim="d3", anomaly_type_lower_higher="warning_higher"),
    ]
    actions = state.process_config(
        config_name="c1", slack_channel_id="C1", thread_timeout_hours=24,
        deltas_rows=rows, open_incident=None, open_replies=[], now=NOW,
    )
    opens = [a for a in actions if type(a).__name__ == "OpenIncident"]
    creates = [a for a in actions if type(a).__name__ == "CreateReply"]
    assert len(opens) == 1
    assert len(creates) == 3
    summary = next(a for a in actions
                   if type(a).__name__ == "UpdateParentSummary")
    assert summary.counts["critical_higher"] == 2
    assert summary.counts["warning_higher"] == 1


def test_no_anomaly_no_incident_no_actions():
    actions = state.process_config(
        config_name="c1", slack_channel_id="C1", thread_timeout_hours=24,
        deltas_rows=[], open_incident=None, open_replies=[], now=NOW,
    )
    assert actions == []


def test_latest_timestamp_wins_for_duplicate_keys():
    # Two rows for the same (dim, method), the more recent one resolves.
    # Older one says critical, newer says normal -> resolve.
    older = _row(anomaly_type_lower_higher="critical_higher",
                 timestamp=NOW - datetime.timedelta(days=3))
    newer = _row(anomaly_type_lower_higher="normal",
                 timestamp=NOW - datetime.timedelta(hours=2))
    actions = state.process_config(
        config_name="c1", slack_channel_id="C1", thread_timeout_hours=24,
        deltas_rows=[older, newer],
        open_incident=_incident(),
        open_replies=[_reply()], now=NOW,
    )
    types = [type(a).__name__ for a in actions]
    assert "ResolveReply" in types
    assert "UpdateReplyClassification" not in types
