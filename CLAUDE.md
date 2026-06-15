<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **anomaly_detection** (77783 symbols, 100893 relationships, 300 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

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

Common cases that have already been deprecated (in both `parsed_row_count_source_daily` and `parser_errors_daily_by_source` unless noted):

- `marinetraffic` (dead since 2026-01-01; only in `parsed_row_count_source_daily` — excluded from `parser_errors_daily_by_source` via `source_filter_sql`).
- `ais-listener` (dead since 2026-05-04).
- `kpler` (dead since 2026-05-08 — replaced by the live `kpler-satellite` / `kpler-terrestrial` / `kpler-roaming` split dims, which ran in parallel from early March).
- `spire` and `exactearth` (ingestion stopped 2026-06-03).

## Time-evolving source metrics (`refetch_recent_days`)

For configs whose source metric grows with wall-clock time — the "now_hypothetical" delay metrics, which depend on `CURRENT_TIMESTAMP()` inside their source views — the default missing-timestamps filter freezes a date's value at first fetch: once the date is in actuals (from sibling dims, or from the day it first crossed `> 0` on single-dim configs), it is never refetched even though the real delay keeps growing. Set `refetch_recent_days: <N>` in the config YAML to force the last N days back into the refetch set; SCD2 handles the value evolution. Currently set (N=14) on `gfw_api_delays` and `s2_index_delays`. Full details in `dataloader/README.md`. **Do not** set this on configs with stable per-day values — it's pure overhead there.

## Promotion roadmap

`ROADMAP.md` at the repo root tracks the dev → staging → prod promotion plan, including the standing gotchas (tag triggers' `included_files` filters, the any-branch trigger planning all three envs, prod Slack routing having no fallback row, the shared Slack mapping seed not being CI-seeded). Read it before any promotion or release-tag work.

## Cold-start backfill on new-env deployment

When a config is deployed to a new environment, its first run scans the full history at once and can exceed the scheduled jobs' 60 GB `allowed_size` cap (the routine daily runs are cheap and stay under it). **Policy:** the person promoting runs the initial backfill manually before the scheduler does, and — only for that supervised one-off run — is allowed to raise `--allowed_size` (the single sanctioned exception to "don't raise cost thresholds without checking"). Never bake the raised value into `config_<env>.yaml` or the scheduled job. Size it from a dry-run estimate; the runtime scan is cluster-pruned so it usually bills far less than the estimate. Full details in `dataloader/README.md`.
