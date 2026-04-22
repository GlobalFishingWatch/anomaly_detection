"""Tests for the identifier validators that gate SQL interpolation."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import bq  # noqa: E402


def test_canonical_table_id_accepts_canonical_triple():
    assert bq.canonical_table_id("proj.dataset.table") == "proj.dataset.table"


def test_canonical_table_id_accepts_hyphens_and_underscores():
    assert bq.canonical_table_id("a-b.c_d.e_f_g") == "a-b.c_d.e_f_g"


@pytest.mark.parametrize("bad", [
    "foo`; DROP TABLE x; --",
    "only_one_part",
    "two.parts",
    "a b.c.d",                  # whitespace
    "a.b.c.d",                  # too many parts
    "proj.dataset.`t`",         # embedded backticks
    "proj.dataset.t)",          # parens
])
def test_canonical_table_id_rejects_injection_attempts(bad):
    with pytest.raises(ValueError):
        bq.canonical_table_id(bad)


def test_canonical_environment_accepts_allowed():
    for env in ("dev", "staging", "main", "prod"):
        assert bq.canonical_environment(env) == env


@pytest.mark.parametrize("bad", [
    "hax",
    "",
    "dev; DROP TABLE x",
    "dev`",
    "DEV",           # case-sensitive
])
def test_canonical_environment_rejects_everything_else(bad):
    with pytest.raises(ValueError):
        bq.canonical_environment(bad)
