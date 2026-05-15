provider "google" {
  project = "world-fishing-827"
}

# OPEN QUESTION (2026-05-15) — which service account should run these
# triggers, and what IAM grants does it need? Today both triggers run as
# `terraform-deployer@world-fishing-827.iam.gserviceaccount.com`
# (consistent with the alerter / dataloader triggers). That SA has
# dataset-level `bigquery.dataEditor` on `tech_anomaly_detection` but
# lacks project-level `bigquery.jobUser`, so `dbt seed` fails with:
#
#   403 ... User does not have bigquery.jobs.create permission in
#   project world-fishing-827.
#
# `bigquery.jobs.create` can only be granted at project scope (BQ IAM
# constraint). Two options under discussion:
#
#   A. Grant terraform-deployer `roles/bigquery.jobUser` at project
#      level in the central gfw-terraform-gcp repo. Smallest change,
#      but widens the SA's effective BQ reach to every dataset it has
#      dataEditor on (currently tech_anomaly_detection and
#      dq-monitoring; potentially more later).
#
#   B. Stand up a dedicated SA in this terraform (`anomaly-detection-
#      dbt-runner`) with project-level jobUser + dataset-level dataEditor
#      on tech_anomaly_detection only, and switch the triggers to run
#      as it. Effective scope is just our dataset; terraform-deployer
#      is untouched. ~5 resources to add. See conversation history for
#      a draft.
#
# Cloud Build runs themselves (i.e. `terraform apply` from this dir to
# create/update the triggers) continue to run as terraform-deployer
# regardless of which option we pick -- only the *trigger execution
# identity* changes.
#
# Cloud Build triggers that run `dbt seed` whenever files under `dbt/`
# change. Two triggers mirror the dataloader/alerter pattern:
#
#   trigger_branch — fires on any branch push. The step itself maps
#                    BRANCH_NAME -> DBT_ENVIRONMENT and no-ops on
#                    feature branches.
#   trigger_tag    — fires on a git tag (release). DBT_ENVIRONMENT=prod.
#
# Steps run inside the prebuilt ghcr.io/dbt-labs/dbt-bigquery image
# pinned to the same minor we install locally (1.8.x). No pip install,
# no adapter assembly. ADC flows in via Cloud Build's metadata server,
# so the inline profile uses `method: oauth` with no key file.

locals {
  subproject_name_dashed_short = "dbt"
  subproject_name_dashed       = "anomaly-detection-dbt"
  dbt_image                    = "ghcr.io/dbt-labs/dbt-bigquery:1.8.1"

  # Inline profile rendered into ./dbt/.dbt/profiles.yml on each run. We
  # base64-encode it before splicing into the bash command so heredoc nesting
  # and shell quoting can't break it.
  profile_yaml_b64 = base64encode(<<-YAML
    anomaly_detection:
      target: default
      outputs:
        default:
          type: bigquery
          method: oauth
          project: world-fishing-827
          dataset: tech_anomaly_detection
          location: US
          threads: 12
          maximum_bytes_billed: 207374182400
  YAML
  )
}


resource "google_cloudbuild_trigger" "trigger_branch" {
  name     = "${local.subproject_name_dashed}-any-branch"
  location = "global"

  included_files = ["${local.subproject_name_dashed_short}/**"]

  github {
    name  = "anomaly_detection"
    owner = "GlobalFishingWatch"

    push {
      branch       = ".*"
      invert_regex = false
    }
  }

  service_account = "projects/world-fishing-827/serviceAccounts/terraform-deployer@world-fishing-827.iam.gserviceaccount.com"

  build {
    timeout = "600s"

    step {
      id         = "branch name"
      name       = "alpine"
      entrypoint = "sh"
      args = [
        "-c",
        <<-EOF
          echo "***********************"
          echo "$BRANCH_NAME"
          echo "***********************"
        EOF
      ]
    }

    step {
      id         = "dbt seed"
      name       = local.dbt_image
      entrypoint = "bash"
      args = [
        "-c",
        <<-EOF
          set -e
          case "$BRANCH_NAME" in
            dev)  ENV=dev ;;
            main) ENV=staging ;;
            *)    echo "skipping dbt seed on branch $BRANCH_NAME"; exit 0 ;;
          esac

          mkdir -p ./dbt/.dbt
          echo '${local.profile_yaml_b64}' | base64 -d > ./dbt/.dbt/profiles.yml

          cd dbt
          DBT_ENVIRONMENT=$$ENV dbt deps --profiles-dir ./.dbt
          DBT_ENVIRONMENT=$$ENV dbt seed --profiles-dir ./.dbt \
            --select "config_descriptions_$$ENV" "thresholds_$$ENV"
        EOF
      ]
    }

    options {
      logging = "CLOUD_LOGGING_ONLY"
    }
  }
}


resource "google_cloudbuild_trigger" "trigger_tag" {
  name     = "${local.subproject_name_dashed}-tag"
  location = "global"

  included_files = ["${local.subproject_name_dashed_short}/**"]

  github {
    name  = "anomaly_detection"
    owner = "GlobalFishingWatch"

    push {
      tag          = ".*"
      invert_regex = false
    }
  }

  service_account = "projects/world-fishing-827/serviceAccounts/terraform-deployer@world-fishing-827.iam.gserviceaccount.com"

  build {
    timeout = "600s"

    step {
      id         = "tag name"
      name       = "alpine"
      entrypoint = "sh"
      args = [
        "-c",
        <<-EOF
          echo "***********************"
          echo "$TAG_NAME"
          echo "***********************"
        EOF
      ]
    }

    step {
      id         = "dbt seed"
      name       = local.dbt_image
      entrypoint = "bash"
      args = [
        "-c",
        <<-EOF
          set -e
          ENV=prod

          mkdir -p ./dbt/.dbt
          echo '${local.profile_yaml_b64}' | base64 -d > ./dbt/.dbt/profiles.yml

          cd dbt
          DBT_ENVIRONMENT=$$ENV dbt deps --profiles-dir ./.dbt
          DBT_ENVIRONMENT=$$ENV dbt seed --profiles-dir ./.dbt \
            --select "config_descriptions_$$ENV" "thresholds_$$ENV"
        EOF
      ]
    }

    options {
      logging = "CLOUD_LOGGING_ONLY"
    }
  }
}
