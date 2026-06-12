# Roadmap: dev → staging → prod promotion

Status as of 2026-06-12. Live-state audit notes in the 2026-06-10 verification (see CHANGELOG and
`CLAUDE.md`); staging and prod jobs have been failing on missing v2 BQ tables since April 2025.

## 1. Unblock staging (next up)

Mechanically: PR `dev` → `main`, merge. The Cloud Build triggers do the heavy lifting.

Pre-merge checklist (all on `dev`):

- [x] Port `deprecated_dims` to `config_staging.yaml` (`parsed_row_count_source_daily`,
      `parser_errors_daily_by_source`) and `refetch_recent_days: 14` to its `gfw_api_delays`.
- [ ] Review `terraform plan` output in the merge-day build logs: `t_staging_actuals` /
      `t_staging_forecasts` are tracked in tfstate but were deleted from BQ out-of-band, so the
      apply recreates them empty. Surprises here mean someone else touched state.
- [ ] No changes needed to the shared Slack mapping seed for staging (fallback row
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

- [ ] All staging dataloader executions green (watch heavier full-history configs against the
      1200s job timeout — all 11 schedulers fire at 10:20 UTC simultaneously).
- [ ] `bq ls tech_anomaly_detection` shows all six staging tables.
- [ ] Bootstrap marker rows present in the staging incidents table; no marinetraffic /
      ais-listener / spire / exactearth / kpler fires.

## 2. Promote gfw_api_delays to prod

Scope decision (2026-06-12): prod starts with `gfw_api_delays` only.

Prep (on `dev`, flows to `main` before tagging):

- [ ] Add `gfw_api_delays` block to `config_prod.yaml` (copy from staging incl.
      `refetch_recent_days: 14`).
- [ ] Add `gfw_api_delays` rows to `thresholds_prod.csv` + `config_descriptions_prod.csv`.
- [ ] Add a prod Slack mapping row for `gfw_api_delays` to the shared mapping seed — **prod has
      no fallback row**. Since the 2026-06-12 routing fix an unmapped prod config is skipped with
      a `[channel-routing]` error in the job logs (it previously misrouted to an arbitrary
      channel); either way its alerts go nowhere until the row exists.
- [ ] Manually run `dbt seed --select slack_channels_environments_config_mapping` — the shared
      mapping seed is NOT in the CI `--select` list; forgetting it silently keeps old routing.
- [ ] Decide: keep or drop `parser_errors_daily` in prod (currently its only config).

Release:

- [ ] Let staging soak (suggest ≥1 week), then tag `v0.0.5` on `main`.
- [ ] **Verify all three tag builds fired** (`gcloud builds list`). Tag triggers have
      `included_files` filters — this is how prod's dataloader got stuck on v0.0.3 while the
      alerter moved to v0.0.4. Run missing triggers manually:
      `gcloud builds triggers run <name> --tag=<tag>`.
- [ ] Same bootstrap suppression protects prod's first alerter run; confirm bootstrap markers
      before trusting the channel. Prod `parser_errors_daily` routes to `C08PGM43PDK` (real
      audience).

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
