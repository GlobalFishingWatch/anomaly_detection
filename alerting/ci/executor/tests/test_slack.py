"""Unit tests for slack.py renderers. Pure-string output, no API calls."""

from __future__ import annotations

import datetime
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import slack as slacklib  # noqa: E402


DATE = datetime.date(2026, 4, 22)
LOOKER = "https://looker.example/y"


def _row(**overrides):
    base = {
        "dimension_split_value": "d1",
        "forecast_method": "mstl",
        "anomaly_type_lower_higher": "critical_higher",
        "timestamp": datetime.datetime(2026, 4, 22, 0, 0,
                                       tzinfo=datetime.timezone.utc),
        "forecast_value": 1.0,
        "actual_value": 2.5,
        "delta_rel": 1.5,
        "source_sql": "",
    }
    base.update(overrides)
    return base


# --- DQ link in the opener (header) ------------------------------------

def test_opener_renders_dq_link_when_url_set():
    text = slacklib.render_thread_opener(
        "c1", DATE, "prod", "d", LOOKER, severity="critical",
        dq_dashboard_url="https://dq.example/x",
    )
    assert "*DQ dashboard*: <https://dq.example/x|open>" in text


def test_opener_omits_dq_link_when_url_empty():
    text = slacklib.render_thread_opener(
        "c1", DATE, "prod", "d", LOOKER, severity="critical",
        dq_dashboard_url="",
    )
    assert "DQ dashboard" not in text


def test_opener_omits_dq_link_when_url_whitespace():
    text = slacklib.render_thread_opener(
        "c1", DATE, "prod", "d", LOOKER, severity="critical",
        dq_dashboard_url="   ",
    )
    assert "DQ dashboard" not in text


def test_opener_omits_dq_link_when_url_none():
    text = slacklib.render_thread_opener(
        "c1", DATE, "prod", "d", LOOKER, severity="critical",
    )
    assert "DQ dashboard" not in text


# --- text_inject placement (always last on every return path) ----------

def test_opener_appends_text_inject_at_end_of_slim_form():
    text = slacklib.render_thread_opener(
        "c1", DATE, "prod", "the description", LOOKER,
        severity="critical",
        text_inject="cc <!subteam^S1>",
    )
    assert text.rstrip().endswith("cc <!subteam^S1>")


def test_opener_with_first_fire_row_keeps_inject_after_fire_body():
    fire_row = _row()
    text = slacklib.render_thread_opener(
        "c1", DATE, "prod", "d", LOOKER,
        severity="critical",
        first_fire_row=fire_row,
        text_inject="ping",
    )
    # Fire-body markers (e.g. *Relative delta*) come before the inject.
    assert text.index("Relative delta") < text.index("ping")
    assert text.rstrip().endswith("ping")


def test_opener_with_counts_keeps_inject_after_counts_table():
    counts = {"critical_higher": 2, "critical_lower": 0,
              "warning_higher": 1, "warning_lower": 0}
    text = slacklib.render_thread_opener(
        "c1", DATE, "prod", "d", LOOKER,
        severity="critical",
        counts=counts,
        text_inject="<@U1> <@U2>",
    )
    # Counts table is fenced markdown; the inject appears after the closing fence.
    assert text.rstrip().endswith("<@U1> <@U2>")
    assert text.index("```") < text.index("<@U1>")


def test_opener_omits_inject_block_when_empty():
    text = slacklib.render_thread_opener(
        "c1", DATE, "prod", "d", LOOKER, severity="normal",
    )
    # Last printable line is the description (italics).
    assert "subteam" not in text
    assert "<@" not in text
    assert text.endswith("_d_")


def test_opener_omits_inject_block_when_whitespace():
    text = slacklib.render_thread_opener(
        "c1", DATE, "prod", "d", LOOKER, severity="normal",
        text_inject="   \n  ",
    )
    assert text.endswith("_d_")


# --- replies are NOT touched by either feature -------------------------

def test_fire_body_does_not_contain_dq_dashboard_line():
    """Locks in the user's 'opener only' decision: per-fire replies stay
    unchanged, no DQ link in the fire body."""
    text = slacklib._render_fire_body(_row(), LOOKER)
    assert "DQ dashboard" not in text


def test_severity_change_does_not_contain_dq_dashboard_line():
    text = slacklib.render_severity_change(
        _row(), "warning_higher", "critical_higher", LOOKER)
    assert "DQ dashboard" not in text


def test_render_fire_does_not_contain_inject():
    text = slacklib.render_fire(_row(), LOOKER)
    assert "subteam" not in text
    assert "<@" not in text
