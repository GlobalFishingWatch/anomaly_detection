provider "google" {
  project = "world-fishing-827"
}

locals {
  subproject_name_dashed_short = "dataloader"
  subproject_name_dashed = "anomaly-detection-dataloader"
}

resource "google_cloudbuild_trigger" "trigger_branch" {
  name     = "${local.subproject_name_dashed}-any-branch"
  location = "global"

  included_files = [ "${local.subproject_name_dashed_short}/**" ]
  ignored_files = [ "${local.subproject_name_dashed_short}/cloudbuild/**" ]

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
    timeout = "3600s"
    
    step {
      id   = "docker build"
      name = "gcr.io/kaniko-project/executor:latest"
      timeout = "3600s"
      args = [
        "--destination=gcr.io/world-fishing-827/github.com/globalfishingwatch/${local.subproject_name_dashed}:$COMMIT_SHA",
        "--destination=gcr.io/world-fishing-827/github.com/globalfishingwatch/${local.subproject_name_dashed}:$BRANCH_NAME-latest",
        "--cache=true",
        "--cache-ttl=48h",
        "--cache-repo=gcr.io/world-fishing-827/github.com/globalfishingwatch/kaniko-cache",
        "--dockerfile=./${local.subproject_name_dashed_short}/ci/executor/Dockerfile",
        "--context=./${local.subproject_name_dashed_short}/ci/executor",
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
          for dir in ${local.subproject_name_dashed_short}/deploy/environments/*/
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
          for dir in ${local.subproject_name_dashed_short}/deploy/environments/*/
          do
            cd $${dir}
            env=$${dir%*/}
            env=$${env#*/}
            echo ""
            echo "*************** TERRAFOM PLAN ******************"
            echo "******* At environment: $${env} ********"
            echo "*************************************************"
            if [ $${env} = "dev" ]; then
              terraform plan -var "docker_image=gcr.io/world-fishing-827/github.com/globalfishingwatch/${local.subproject_name_dashed}:$COMMIT_SHA" || exit 1
            elif [ $${env} = "staging" ]; then
              terraform plan -var "docker_image=gcr.io/world-fishing-827/github.com/globalfishingwatch/${local.subproject_name_dashed}:$COMMIT_SHA" || exit 1
            elif [ $${env} = "release" ]; then
              terraform plan -var "docker_image=gcr.io/world-fishing-827/github.com/globalfishingwatch/${local.subproject_name_dashed}:$COMMIT_SHA" || exit 1
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
        if [ -d ./${local.subproject_name_dashed_short}/deploy/environments/$BRANCH_NAME ]; then
          cd ./${local.subproject_name_dashed_short}/deploy/environments/$BRANCH_NAME
          echo ""
          echo "*************** TERRAFOM APPLY ******************"
          echo "******* At environment: $BRANCH_NAME ********"
          echo "*************************************************"
          if [ $BRANCH_NAME = "dev" ]; then
            terraform apply -auto-approve -var "docker_image=gcr.io/world-fishing-827/github.com/globalfishingwatch/${local.subproject_name_dashed}:$COMMIT_SHA" || exit 1
          elif [ $BRANCH_NAME = "main" ]; then
            terraform apply -auto-approve -var "docker_image=gcr.io/world-fishing-827/github.com/globalfishingwatch/${local.subproject_name_dashed}:$COMMIT_SHA" || exit 1
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
      images = ["gcr.io/world-fishing-827/github.com/globalfishingwatch/${local.subproject_name_dashed}:$BRANCH_NAME-latest", "gcr.io/world-fishing-827/github.com/globalfishingwatch/${local.subproject_name_dashed}:$COMMIT_SHA"]
    }
    options {
      logging = "CLOUD_LOGGING_ONLY"
    }
  }
}


resource "google_cloudbuild_trigger" "trigger_tag" {
  name     = "${local.subproject_name_dashed}-tag"
  location = "global"

  included_files = [ "${local.subproject_name_dashed_short}/**" ]

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

    timeout = "3600s"

    
    
    step {
      id   = "docker build"
      name = "gcr.io/kaniko-project/executor:latest"
      timeout = "3600s"
      args = [
        "--destination=gcr.io/world-fishing-827/github.com/globalfishingwatch/${local.subproject_name_dashed}:$COMMIT_SHA",
        "--destination=gcr.io/world-fishing-827/github.com/globalfishingwatch/${local.subproject_name_dashed}:$BRANCH_NAME-latest",
        "--cache=true",
        "--cache-ttl=48h",
        "--cache-repo=gcr.io/world-fishing-827/github.com/globalfishingwatch/kaniko-cache",
        "--dockerfile=./${local.subproject_name_dashed_short}/ci/executor/Dockerfile",
        "--context=./${local.subproject_name_dashed_short}/ci/executor",
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

          cd ./${local.subproject_name_dashed_short}/deploy/environments/release
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

          cd ./${local.subproject_name_dashed_short}/deploy/environments/release
          echo ""
          echo "*************** TERRAFOM PLAN ******************"
          echo "******* At environment: release ********"
          echo "*************************************************"
          terraform plan -var "docker_image=gcr.io/world-fishing-827/github.com/globalfishingwatch/${local.subproject_name_dashed}:$TAG_NAME" || exit 1
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
          cd ./${local.subproject_name_dashed_short}/deploy/environments/release
          echo ""
          echo "*************** TERRAFOM APPLY ******************"
          echo "******* At environment: release ********"
          echo "*************************************************"

          terraform apply -auto-approve -var "docker_image=gcr.io/world-fishing-827/github.com/globalfishingwatch/${local.subproject_name_dashed}:$TAG_NAME" || exit 1
        EOF
      ]
    }

    artifacts {
      images = ["gcr.io/world-fishing-827/github.com/globalfishingwatch/${local.subproject_name_dashed}:$TAG_NAME"]
    }
    options {
      logging = "CLOUD_LOGGING_ONLY"
    }
  }
}
