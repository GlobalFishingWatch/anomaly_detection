"""Tests for the two-tier Slack channel routing lookup."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import bq  # noqa: E402


class _FakeJob:
    def __init__(self, rows):
        self._rows = rows

    def result(self):
        return self._rows


class _FakeClient:
    def __init__(self, rows):
        self._rows = rows
        self.queries = []

    def query(self, query, job_config=None):
        self.queries.append(query)
        return _FakeJob(self._rows)


def test_returns_channel_when_mapping_exists():
    client = _FakeClient([{"slack_channel_id": "C1",
                           "slack_channel_name": "#one"}])
    out = bq.get_channel_config(client, "cfg", "dev")
    assert out == {"slack_channel_id": "C1", "slack_channel_name": "#one"}


def test_raises_when_no_mapping_matches():
    client = _FakeClient([])
    with pytest.raises(ValueError, match="cfg/prod"):
        bq.get_channel_config(client, "cfg", "prod")


def test_query_restricts_to_exact_or_env_fallback():
    """Locks out the old tier-3 'first row of the whole table' fallback,
    which silently routed unmapped configs to an arbitrary channel."""
    client = _FakeClient([{"slack_channel_id": "C1",
                           "slack_channel_name": "#one"}])
    bq.get_channel_config(client, "cfg", "dev")
    (query,) = client.queries
    assert "WHERE" in query
    assert "config_name IS NULL AND environment = @environment" in query
    assert "ELSE 3" not in query
