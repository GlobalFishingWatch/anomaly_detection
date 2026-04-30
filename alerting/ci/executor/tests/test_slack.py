"""Unit tests for slack.py renderers. Pure-string output, no API calls."""

from __future__ import annotations

import datetime
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import slack as slacklib  # noqa: E402


DATE = datetime.date(2026, 4, 22)
LOOKER = "https://looker.example/y"


# --- make_looker_studio_url --------------------------------------------

# Reference URL pasted verbatim from a real dashboard apply-filters round-trip
# (parsed_row_count_main_types_daily / mean / dim '1'). The builder must match
# this byte-for-byte so deep-links land on a filtered view, not just one with
# parameter values set.
_EXPECTED_DASHBOARD_URL = (
    "https://datastudio.google.com/u/0/reporting/"
    "1f9b8d37-a87b-4177-a108-3b3e87ce5804/page/p_ufk1l0slhd"
    "?params=%7B%22PARAM_CONFIG_NAME%22:%22parsed_row_count_main_types_daily%22"
    ",%22PARAM_FC%22:%22mean%22,%22PARAM_DIMENSION%22:%221%22"
    ",%22df34%22:%22include%25EE%2580%25800%25EE%2580%2580IN%25EE%2580%2580"
    "parsed_row_count_main_types_daily%22"
    ",%22df43%22:%22include%25EE%2580%25800%25EE%2580%2580IN%25EE%2580%25801%22%7D"
)


def test_make_looker_studio_url_matches_dashboard_apply_filters_output():
    url = slacklib.make_looker_studio_url(
        "1f9b8d37-a87b-4177-a108-3b3e87ce5804", "p_ufk1l0slhd",
        "parsed_row_count_main_types_daily", "mean", "1")
    assert url == _EXPECTED_DASHBOARD_URL


def test_make_looker_studio_url_drops_filter_params_when_value_empty():
    """Empty config_name / dimension would filter out everything, so we omit
    the corresponding df param. PARAM_* still get set (they're report
    variables, not filters)."""
    url = slacklib.make_looker_studio_url(
        "rep", "p", config_name="", forecast_method="mean", dimension="")
    assert "df34" not in url
    assert "df43" not in url
    assert "PARAM_CONFIG_NAME" in url
    assert "PARAM_FC" in url
    assert "PARAM_DIMENSION" in url


def test_make_looker_studio_url_uses_compact_json_and_unencoded_separators():
    """Spaces in the JSON output (default json.dumps separator) and percent-
    encoded ':' or ',' (default urllib.parse.quote safe set) both broke the
    dashboard parser. Lock those two regressions in explicitly."""
    url = slacklib.make_looker_studio_url("rep", "p", "c", "m", "1")
    assert "%20" not in url           # no spaces
    assert "%3A" not in url           # ':' kept literal
    assert "%2C" not in url           # ',' kept literal


def test_make_looker_studio_url_uses_datastudio_domain():
    url = slacklib.make_looker_studio_url("rep", "p", "c", "m", "1")
    assert url.startswith("https://datastudio.google.com/u/0/reporting/rep/page/p?params=")


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
