# Anomaly status pages: expert + internal + public

Companion to the Slack alerting system. Slack is the incremental firehose;
these pages give top-down state and a curated narrative. Three tiers
share one BigQuery data layer; the workflow is progressively gated as the
audience broadens.

## Context

The existing Slack alerter ships per-(config, anomaly_date) thread notifications
with append-only replies (see `analysis/alerting_v2_1_plan.md`). It does not
provide a top-down view of current state, and threads are hard to scan at a
glance.

A parallel manual-curation workflow lives in a spreadsheet
("API daily status - manually maintained issue inventory") with columns
`Date`, `Name`, `Status`, `Comment`, `Details`, `Link`, `Comms: internal`,
`Comms: external`, `Updates`. Status values observed in use:
`EXPECTED OK`, `OK`, `EXPECTED RECOVERY`, `NOT OK`. That spreadsheet carries
three things the raw data cannot: forward-looking status, user-facing
narrative, and a time-stamped update log. Any design must make room for
that curation as a first-class layer.

Frontend choice (see prior decision): Astro. Reasons (truncated): static
HTML output, no proprietary AI framework, fully customisable, build-time
BQ queries, reviewable diffs, progressive gating fits naturally.

## Architecture: four layers

1. **Raw BQ data** (exists today): `t_{env}_deltas`,
   `t_alerting_incidents`, `t_alerting_incident_replies`, seed tables.
2. **Derived BQ views** (new): `v_current_state`, `v_config_rollup`,
   `v_product_rollup`, `v_severity_ribbon_14d`. Materialised, ~15 min
   refresh. Single source for all three views.
3. **Curated overlay** (replaces / complements the spreadsheet): per-date
   x per-product status with `EXPECTED_OK / OK / EXPECTED_RECOVERY / NOT_OK`,
   comment, internal-vs-external flag, updates log.
4. **Documentation**: per-config rich descriptions + concepts glossary
   (`dimension-split`, `data-date vs detection-date`,
   `forecast-method-mstl`, thresholds / deltas, ...). Markdown-authored.

## Three views, by priority

### 1. Expert view (highest priority, fully automated)

- **Home**: every prod config as a row, grouped by product. Shows current
  severity, "N of M dims critical" badge, last-fired timestamp, and an
  open-incident link where applicable.
- **Config detail page** (one per config):
  - Rich description from `/docs/configs/<config>.md` -- replaces the
    one-line CSV. Covers what it detects, how computed (source table +
    forecast method + period), how to read the chart, and a
    "known-noise" section that accumulates over time.
  - Inline glossary callouts for terms appearing on the page (popovers
    drawing from `/docs/concepts/`).
  - Time-series chart: `actual_value` + `forecast_value` lines, shaded
    warning/critical bands, anomaly dots. Same shape as the existing
    Looker panel, rebuilt in Observable Plot (or visx) against the same
    `t_{env}_deltas`.
  - Dimension grid for configs with a split, sorted by severity.
  - Recent anomalies table with links out to Slack incidents.
- Auto-deploys hourly. No human gate -- the audience is data engineers.

### 2. Internal (GFW-wide) view (fully automated)

- **Home**: product cards (AIS, GFW API, pipe3 products, BQ billing, ...).
  Each card shows: overall severity rolled up from configs, 14-day
  severity ribbon, **current curated comment** if one exists for today.
- **Product detail page** lists affected configs with:
  - A one-line plain-English explanation (a separate field on
    `/docs/configs/<config>.md`, not the expert version).
  - Glossary tooltips (not inline explanations).
  - "Drill into expert view" link -> config detail page above.
- Auto-deploys hourly. Shows curated narrative where it exists and
  terse-but-explained data where it doesn't.

### 3. Public status page (PR-gated)

- Product cards only. Narrative is **100% human-curated** -- a
  (product, day) only appears if a curator has published a comment for it.
- `EXPECTED RECOVERY` surfaces as "recovering".
- No raw metrics, thresholds, dimension splits, or jargon.
- Historical view via a date selector mirroring the spreadsheet's shape.
- Most common public-facing scenarios (from domain context):
  - API endpoint delays with impact explanation (e.g. "public-global-
    encounter-events has larger-than-expected delay -> map not showing
    encounters since date X").
  - Partial missing data for the most recent period.
  - Historical data bug affecting all data (rare; also goes on data
    updates website + newsletter).

## Curation workflow (replaces / complements the spreadsheet)

Three authoring options:

- **A. Files in git.** One markdown file per (date, product) with
  frontmatter (status, comms flags, slack link) and body (narrative).
  PR to edit. Git log = audit trail. Heavy for routine daily entries.
- **B. Keep the spreadsheet, sync to BQ.** Apps Script (or scheduled
  Cloud Run) reads the sheet into `t_curated_status`. Build queries the
  table. Zero workflow change today. Downside: spreadsheet becomes
  load-bearing.
- **C. Hybrid (recommended).** Start with B -- no disruption. Add A
  *only* for the public tier, since it needs PR gating anyway and
  benefits from git history. Internal curators keep the sheet. Migrate
  wholesale to A if the sheet later becomes painful.

The sheet's columns map directly to `t_curated_status` fields.
`Comms: external` gates a row onto the public page.

## Repository layout

Sibling repo, e.g. `anomaly_detection_status`. Different release cadence
from the alerter; different review discipline on the public tier.

```
/queries/              # .sql files run at build time
/data/                 # JSON snapshots of query results, committed
/docs/
  configs/<name>.md    # rich per-config docs
  concepts/<name>.md   # glossary
/curated/              # (option A/C) markdown overlay for public tier
/src/
  pages/
    expert/            # auto-deployed
    internal/          # auto-deployed
    public/            # PR-gated
  components/          # charts, ribbons, product cards
/.github/workflows/
  build-auto.yml       # hourly -> expert + internal, auto-deploy
  build-public.yml     # hourly -> public, PR-gated
```

## Build & publish workflow

**`build-auto.yml`** (hourly):
1. Run `/queries/*.sql` against BQ.
2. Write canonicalised JSON snapshots into `/data/`.
3. Commit data changes with `[auto-data]` prefix (deterministic content,
   git diff is the forensic trail).
4. Build expert + internal Astro pages.
5. Deploy to internal URL.

**`build-public.yml`** (hourly):
1. Same data refresh.
2. Build public Astro page (consumes curated narrative + data).
3. Diff canonicalised JSON snapshot of the public data against the
   currently-published one.
4. If changed: open or update a PR on `public-propose` branch.
5. Reviewer approves -> merge -> deploy.

Progressive AI-in-the-loop lives in step 4 of `build-public.yml`:
- **Stage 1** (today): human reviews every public PR.
- **Stage 2**: Claude Code agent comments on the PR with a diff summary
  and a first-pass verdict (corroborated by internal dashboard state?
  matches an open Slack incident?); human still merges.
- **Stage 3**: agent auto-approves low-risk changes, humans see
  escalations only.
- **Stage 4** (optional): full auto-merge with PR history as audit trail.

No framework switch between stages -- just more reviewers in the
workflow file.

## Why Astro supports this cleanly

Each rebuild produces a deterministic artefact committed to git. The
*data layer* (JSON snapshots) is the review surface, not the rendered
HTML. Reviewers read `public-data-snapshot.json`'s diff; HTML is the
render of that. This also makes regression testing trivial (has the
public state changed since yesterday? = JSON diff). Same mechanism
works for any future AI-in-the-loop.

## v0: prove the stack on the expert tier only

Don't attempt all three views at once.

1. Bootstrap Astro repo + hourly GitHub Action + BQ auth.
2. Write `/queries/current_state.sql` using the `QUALIFY ROW_NUMBER()`
   pattern already in `alerting/ci/executor/bq.py`.
3. Write `/docs/configs/<one-config>.md` as exemplar. Proposed:
   `parser_errors_daily_by_source` (has a dim split and recent real
   anomalies -- good exercise for the rich-description pattern).
4. Render the config detail page end-to-end: description + glossary +
   chart + dim grid + recent anomalies.
5. Render the expert home page listing all configs (no detail pages for
   the rest yet).
6. Deploy to an internal URL. Iterate with a real user on the chart +
   doc layout.

Then expand: fill in the other configs' docs, build the internal view,
then design the public one (with its curation feed + PR gate) against
the spreadsheet's actual content.

## Decisions needed before starting

1. **Curation workflow**: B or C? Default: C.
2. **Product grouping**: new hand-curated `config_to_product.csv`, or
   derive from dataset naming conventions?
3. **Repository location**: sibling repo (leaning this way) or
   `anomaly_detection/site/` subfolder?
4. **Chart library**: Observable Plot (leaning) or visx/d3?
5. **v0 exemplar config**: `parser_errors_daily_by_source` proposed --
   agree or swap?

## Estimated effort

- v0 (expert tier, one exemplar config end-to-end): 3-5 engineer-days.
- Expand to all configs + internal view: +3-5 days.
- Public view + curation feed + PR-gate workflow: +3-5 days, driven
  mostly by the authoring-surface decision and writing glossary docs.

Totals roughly 2-3 weeks of focused work to get all three tiers live.
AI-in-the-loop stages 2-4 are incremental from there.
