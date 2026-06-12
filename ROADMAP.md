# Roadmap: dev → staging → prod promotion

Status as of 2026-06-12. Live-state audit notes in the 2026-06-10 verification (see CHANGELOG and
`CLAUDE.md`); staging and prod jobs have been failing on missing v2 BQ tables since April 2025.

## 1. Unblock staging — DONE 2026-06-12 (PR #25, merge `2ed0c1d`)

Mechanically: PR `dev` → `main`, merge. The Cloud Build triggers do the heavy lifting.

Pre-merge checklist (all on `dev`):

- [x] Port `deprecated_dims` to `config_staging.yaml` (`parsed_row_count_source_daily`,
      `parser_errors_daily_by_source`) and `refetch_recent_days: 14` to its `gfw_api_delays`.
- [x] Terraform applied cleanly on merge: `t_staging_actuals` / `t_staging_forecasts` recreated
      (they were tfstate-tracked but deleted from BQ out-of-band), incidents/replies tables
      created, schedulers reconciled (11 dataloader + hourly alerter).
- [x] No changes needed to the shared Slack mapping seed for staging (fallback row
      `C08PNGD7W84` already live).

Expected automatic effects of the merge:

- Dataloader + alerter images rebuilt and deployed to staging; alerter timeout goes 600s → 1800s.
- Terraform recreates `t_staging_actuals`/`_forecasts`, creates the staging incidents/replies
  tables, reconciles schedulers.
- dbt CI re-seeds `t_thresholds_staging` / `t_config_descriptions_staging`.
- `t_staging_deltas` materialises at the end of the first successful dataloader run; the hourly
  alerter goes green within the hour after that.
- First alerter run bootstrap-suppresses all historical anomalies (empty incidents table = every
  config first-seen) — no alert storm in `#gfw-dq-alerts-staging`.

Verification after merge day:

- [ ] All staging dataloader executions green on the first full fleet run, 10:20 UTC 2026-06-13
      (watch heavier full-history configs against the 1200s job timeout — all 11 schedulers fire
      simultaneously). `gfw_api_delays` already verified green via a manual scheduler force-run
      on merge day: 437 delta rows / 16 dims through 2026-06-09.
- [x] `bq ls tech_anomaly_detection` shows all six staging tables (deltas materialised after the
      manual `gfw_api_delays` run; both jobs on image `2ed0c1d`, alerter timeout 1800s).
- [x] Bootstrap suppression verified on the first green alerter run (first since April 2025):
      5 historical `gfw_api_delays` dates marked `BOOTSTRAP-`, 0 real threads, 0 Slack posts.
- [ ] After the 2026-06-13 fleet run: no marinetraffic / ais-listener / spire / exactearth /
      kpler fires from the source-split configs.

## 2. Promote gfw_api_delays to prod

Scope decisions (2026-06-12): prod runs `gfw_api_delays` only; `parser_errors_daily` is dropped
from prod (its YAML block removal auto-destroys its prod scheduler on the next tag apply; prod
has no v2 incidents tables yet, so nothing to close or tombstone). Prod alerts route to
`#gfw-dq-alerts-public` (`C09RTAR5PFZ`).

Prep (on `dev`, flows to `main` before tagging) — done 2026-06-12:

- [x] `config_prod.yaml`: replaced `parser_errors_daily` with the `gfw_api_delays` block
      (copied from staging incl. `refetch_recent_days: 14`).
- [x] `thresholds_prod.csv`: swapped to `gfw_api_delays,constant_value,,1,,` (same threshold as
      dev/staging). `config_descriptions_prod.csv` already had the `gfw_api_delays` row.
- [x] Shared Slack mapping seed: replaced the `parser_errors_daily/prod` row with
      `gfw_api_delays,prod,C09RTAR5PFZ,gfw-dq-alerts-public`. **Prod has no fallback row** —
      since the 2026-06-12 routing fix an unmapped prod config is skipped with a
      `[channel-routing]` error; either way its alerts go nowhere until the row exists.
- [x] Manual `dbt seed --select slack_channels_environments_config_mapping` (NOT CI-seeded).
- [ ] Verify the QA Slack bot is a member of `#gfw-dq-alerts-public` before the first prod
      alerter run — `chat.postMessage` fails with `not_in_channel` otherwise.

Release:

- [ ] Let staging soak (suggest ≥1 week), then tag `v0.0.5` on `main`.
- [ ] **Verify all three tag builds fired** (`gcloud builds list`). Tag triggers have
      `included_files` filters — this is how prod's dataloader got stuck on v0.0.3 while the
      alerter moved to v0.0.4. Run missing triggers manually:
      `gcloud builds triggers run <name> --tag=<tag>`.
- [ ] Same bootstrap suppression protects prod's first alerter run; confirm bootstrap markers
      before trusting the channel. Prod `gfw_api_delays` routes to `#gfw-dq-alerts-public`
      (`C09RTAR5PFZ`) — a real audience, so verify the bootstrap markers and bot membership
      before the first alert lands.

## 3. Later / open decisions

- Which remaining dev-only configs go to staging: `pipe3_vs_pipe2_5_published_fishing_*` (3),
  `s2_index_delays`, `s2_published_detections_delays`, `pipe3_product_events_fishing_count`,
  `pipe3_product_events_fishing_count_esp`.
- `s2_index_delays` thresholds (added 2026-06-12: warning > ~35h, critical > ~48h, see
  `dataloader/README.md`) — observe a few weeks on dev and tune before promoting it anywhere.
- Periodic stale-source cleanup job (detect dims that stopped publishing and propose
  `deprecated_dims` entries semi-automatically) — kpler/spire/exactearth each took manual
  discovery.

## Standing gotchas (apply to every promotion)

- The any-branch Cloud Build trigger runs `terraform plan` for **all three** envs and fails the
  build on any error — a broken `config_prod.yaml` blocks even dev deploys.
- Tag triggers only rebuild components whose files changed (`included_files`) — always verify
  all expected tag builds ran.
- Prod Slack routing has no fallback row — every prod config needs an explicit mapping row.
  Since the 2026-06-12 fix, an unmapped config's thread is skipped with a `[channel-routing]`
  error log; its alerts are dropped (not misrouted) until the mapping row lands.
- The shared Slack mapping seed needs a manual `dbt seed` run; CI does not seed it.
- `t_<env>_deltas` is not terraform-managed — it appears only after the first successful
  dataloader run in that env.
