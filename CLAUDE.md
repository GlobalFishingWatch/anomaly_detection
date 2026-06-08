<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **anomaly_detection** (77771 symbols, 100885 relationships, 300 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/anomaly_detection/context` | Codebase overview, check index freshness |
| `gitnexus://repo/anomaly_detection/clusters` | All functional areas |
| `gitnexus://repo/anomaly_detection/processes` | All execution flows |
| `gitnexus://repo/anomaly_detection/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->

## Deprecating dims / configs

The dataloader supports two kinds of deprecation. Full details in `dataloader/README.md`.

- **Per-dim**: add the `dimension_split_value` to `deprecated_dims` in the relevant config block of `dataloader/ci/executor/config_<env>.yaml`. `forecast.R` filters `dt_train` before the forecast loop, so no new forecasts are generated for the dim and the alerter stops firing on it within ~7 days. Historical actuals stay in BQ for forensic / dashboard use; new actuals are recorded normally if the dim ever resumes publishing.
- **Per-config**: delete the config block from `config_<env>.yaml` AND the matching `google_cloud_scheduler_job` from `dataloader/deploy/template/main.tf`. Optionally tombstone historical actuals/forecasts and close open incidents (see README checklist).

Do **not** use `deprecated_dims` for time-bounded silencing — it's permanent (until manually un-deprecated). For the rare temporary case, talk to the alerting team rather than abusing this field.

Common cases that have already been deprecated:

- `parsed_row_count_source_daily / marinetraffic` (source dead since 2026-01-01).
- `parsed_row_count_source_daily / ais-listener` and `parser_errors_daily_by_source / ais-listener` (source dead since 2026-05-04).

## Time-evolving source metrics (`refetch_recent_days`)

For configs whose source metric grows with wall-clock time — currently only `gfw_api_delays`, whose `timestamp_delay_now_hypothetical_vs_expected_delay_hour` depends on `CURRENT_TIMESTAMP()` inside `v_scraped_api_values` — the default missing-timestamps filter silently skips dims that cross the alert threshold *after* their date is already in actuals (from sibling dims). Set `refetch_recent_days: <N>` in the config YAML to force the last N days back into the refetch set; SCD2 handles the value evolution. Full details in `dataloader/README.md`. **Do not** set this on configs with stable per-day values — it's pure overhead there.
