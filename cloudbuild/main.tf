provider "google" {
  project = "world-fishing-827"
}

resource "google_cloudbuild_trigger" "trigger_branch" {
  name     = "anomaly-detection-branch"
  location = "global"

  github {
    name  = "anomaly_detection"
    owner = "GlobalFishingWatch"

    push {
      branch       = "^main|dev$"
      invert_regex = false
    }

  }
  service_account = "projects/world-fishing-827/serviceAccounts/terraform-deployer@world-fishing-827.iam.gserviceaccount.com"
  build {

    step {
      id   = "docker build"
      name = "gcr.io/cloud-builders/docker"
      args = [
        "build",
        "-f",
        "./alerting/ci/executor/Dockerfile",
        "-t",
        "gcr.io/world-fishing-827/github.com/globalfishingwatch/anomaly-detection:$COMMIT_SHA",
        "./alerting/ci/executor",
      ]

    }
    step {
      id   = "docker tag"
      name = "gcr.io/cloud-builders/docker"
      args = [
        "tag",
        "gcr.io/world-fishing-827/github.com/globalfishingwatch/anomaly-detection:$COMMIT_SHA",
        "gcr.io/world-fishing-827/github.com/globalfishingwatch/anomaly-detection:$BRANCH_NAME-latest",
      ]

    }
    step {
      id   = "docker push"
      name = "gcr.io/cloud-builders/docker"
      args = [
        "push",
        "gcr.io/world-fishing-827/github.com/globalfishingwatch/anomaly-detection:$COMMIT_SHA"
      ]

    }
    step {
      id         = "branch name"
      name       = "hashicorp/terraform:1.1.5"
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
      id         = "tf init"
      name       = "hashicorp/terraform:1.1.5"
      entrypoint = "sh"
      args = [
        "-c",
        <<-EOF
          for dir in deploy/environments/*/
          do
            cd $${dir}
            env=$${dir%*/}
            env=$${env#*/}
            echo ""
            echo "*************** TERRAFORM INIT ******************"
            echo "******* At environment: $${env} ********"
            echo "*************************************************"
            terraform init || exit 1
            cd ../../../
          done
        EOF
      ]
    }
    step {
      id         = "tf plan"
      name       = "hashicorp/terraform:1.1.5"
      entrypoint = "sh"
      args = [
        "-c",
        <<-EOF
          for dir in deploy/environments/*/
          do
            cd $${dir}
            env=$${dir%*/}
            env=$${env#*/}
            echo ""
            echo "*************** TERRAFOM PLAN ******************"
            echo "******* At environment: $${env} ********"
            echo "*************************************************"
            if [ $${env} = "dev" ]; then
              terraform plan -var "docker_image=gcr.io/world-fishing-827/github.com/globalfishingwatch/anomaly-detection:$COMMIT_SHA" || exit 1
            elif [ $${env} = "staging" ]; then
              terraform plan -var "docker_image=gcr.io/world-fishing-827/github.com/globalfishingwatch/anomaly-detection:$COMMIT_SHA" || exit 1
            elif [ $${env} = "release" ]; then
              terraform plan -var "docker_image=gcr.io/world-fishing-827/github.com/globalfishingwatch/anomaly-detection:$COMMIT_SHA" || exit 1
            fi
            cd ../../../
          done
        EOF
      ]
    }
    step {
      id         = "tf apply"
      name       = "hashicorp/terraform:1.1.5"
      entrypoint = "sh"
      args = [
        "-c",
        <<-EOF
        if [ -d ./deploy/environments/$BRANCH_NAME ]; then
          cd ./deploy/environments/$BRANCH_NAME
          echo ""
          echo "*************** TERRAFOM APPLY ******************"
          echo "******* At environment: $BRANCH_NAME ********"
          echo "*************************************************"
          if [ $BRANCH_NAME = "dev" ]; then
            terraform apply -auto-approve -var "docker_image=gcr.io/world-fishing-827/github.com/globalfishingwatch/anomaly-detection:583b5fc237325f63e6d9c8dbfd8a63cb5f802185" || exit 1
          elif [ $BRANCH_NAME = "main" ]; then
            terraform apply -auto-approve -var "docker_image=gcr.io/world-fishing-827/github.com/globalfishingwatch/anomaly-detection:$COMMIT_SHA" || exit 1
          fi
        else
          echo "***************************** SKIPPING APPLYING *******************************"
          echo "Branch '$BRANCH_NAME' does not represent an oficial environment."
          echo "*******************************************************************************"
        fi
        EOF
      ]
    }

    artifacts {
      images = ["gcr.io/world-fishing-827/github.com/globalfishingwatch/anomaly-detection:$BRANCH_NAME-latest", "gcr.io/world-fishing-827/github.com/globalfishingwatch/anomaly-detection:$COMMIT_SHA"]
    }
    options {
      logging = "CLOUD_LOGGING_ONLY"
    }
  }
}


resource "google_cloudbuild_trigger" "trigger_tag" {
  name     = "anomaly-detection-tag"
  location = "global"

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

    step {
      id   = "docker build"
      name = "gcr.io/cloud-builders/docker"
      args = [
        "build",
        "-f",
        "./alerting/ci/executor/Dockerfile",
        "-t",
        "gcr.io/world-fishing-827/github.com/globalfishingwatch/anomaly-detection:$TAG_NAME",
        "./alerting/ci/executor",
      ]

    }

    step {
      id   = "docker push"
      name = "gcr.io/cloud-builders/docker"
      args = [
        "push",
        "gcr.io/world-fishing-827/github.com/globalfishingwatch/anomaly-detection:$TAG_NAME"
      ]

    }
    step {
      id         = "tag name"
      name       = "hashicorp/terraform:1.1.5"
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
      id         = "tf init"
      name       = "hashicorp/terraform:1.1.5"
      entrypoint = "sh"
      args = [
        "-c",
        <<-EOF

          cd ./deploy/environments/release
          echo ""
          echo "*************** TERRAFORM INIT ******************"
          echo "******* At environment: release ********"
          echo "*************************************************"
          terraform init || exit 1
          cd ../../../

        EOF
      ]
    }
    step {
      id         = "tf plan"
      name       = "hashicorp/terraform:1.1.5"
      entrypoint = "sh"
      args = [
        "-c",
        <<-EOF

          cd ./deploy/environments/release
          echo ""
          echo "*************** TERRAFOM PLAN ******************"
          echo "******* At environment: release ********"
          echo "*************************************************"
          terraform plan -var "docker_image=gcr.io/world-fishing-827/github.com/globalfishingwatch/anomaly-detection:$TAG_NAME" || exit 1
          cd ../../../
        EOF
      ]
    }
    step {
      id         = "tf apply"
      name       = "hashicorp/terraform:1.1.5"
      entrypoint = "sh"
      args = [
        "-c",
        <<-EOF
          cd ./deploy/environments/release
          echo ""
          echo "*************** TERRAFOM APPLY ******************"
          echo "******* At environment: release ********"
          echo "*************************************************"

          terraform apply -auto-approve -var "docker_image=gcr.io/world-fishing-827/github.com/globalfishingwatch/anomaly-detection:$TAG_NAME" || exit 1
        EOF
      ]
    }

    artifacts {
      images = ["gcr.io/world-fishing-827/github.com/globalfishingwatch/anomaly-detection:$TAG_NAME"]
    }
    options {
      logging = "CLOUD_LOGGING_ONLY"
    }
  }
}
