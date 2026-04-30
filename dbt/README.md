# Anomaly detection - DBT

## Description
We use dbt to maintain several hard coded configurations in dbt seeds:
 - thresholds_{environment}: these tables contain anomaly alert thresholds, based upon which alerts with different criticality levels are triggered and visualised in Looker dashboards
 - config_descriptions_{environmnet}: these tables contain anomaly configuration descriptions which can be included in anomaly alerts as well as Looker dashboards to provide details about anomalies

 We also include views that calculate whether anomaly thresholds are exceeded and aggregate data for alerting and the Looker dashboard:
  - v_deltas: this view combines forecasts with actuals, as well as thresholds and descriptions. It also applies debouncing, so anomaly alerts are only send out the first time an anomaly starts and not on subsequent periods

`config_descriptions_*` also carries two optional columns used by the Slack alerter and the static status page:
 - `dq_dashboard_url`: a deep-link to a config-specific page on the team's separate Looker Studio "DQ Dashboard". When set, surfaces as an extra header line in the parent message and as a "DQ dashboard ↗" badge on the status page detail header. See `alerting/README.md` for the rendering rules.
 - `text_inject`: free-form Slack mrkdwn appended to the parent message. Designed for raw mention tokens (`<@U…>`, `<!subteam^S…>`) so subscribers ping exactly once per `(config, anomaly_date)` incident.

## Workflow

### CI/CD (default)

Cloud Build picks up changes under `dbt/**` and runs `dbt seed` for the env that matches the branch. Defined in `dbt/cloudbuild/main.tf`:

| Trigger | Branch / tag | `DBT_ENVIRONMENT` | Reseeds |
| --- | --- | --- | --- |
| `anomaly-detection-dbt-any-branch` | `dev` | `dev` | `t_config_descriptions_dev`, `t_thresholds_dev` |
| `anomaly-detection-dbt-any-branch` | `main` | `staging` | `t_config_descriptions_staging`, `t_thresholds_staging` |
| `anomaly-detection-dbt-tag` | any tag | `prod` | `t_config_descriptions_prod`, `t_thresholds_prod` |

Steps run inside `ghcr.io/dbt-labs/dbt-bigquery:1.8.1` (matches the local `dbt-core==1.8.1` install). The trigger runs as `terraform-deployer@world-fishing-827.iam.gserviceaccount.com`, which already holds `WRITER` on `tech_anomaly_detection` — no additional IAM grants required.

To deploy or update the triggers themselves, run `terraform apply` from `dbt/cloudbuild/`.

### Manual override

Useful when iterating locally or fixing up a seed outside of a normal commit cycle:

```bash
cd dbt
cp profiles.yml.example profiles.yml          # one-time, gitignored
source setenv.sh                               # sets DBT_ENVIRONMENT from branch
dbt seed --profiles-dir . --select "config_descriptions_${DBT_ENVIRONMENT}"
```

For prod use `DBT_ENVIRONMENT=prod` explicitly — `setenv.sh` only maps `dev` and `main`. Local runs use the operator's gcloud identity (`gcloud auth application-default login` first); they need write access to `tech_anomaly_detection`.